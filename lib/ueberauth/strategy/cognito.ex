defmodule Ueberauth.Strategy.Cognito do
  use Ueberauth.Strategy

  def handle_request!(conn) do
    state = :crypto.strong_rand_bytes(32) |> Base.encode16()

    %{
      auth_domain: auth_domain,
      client_id: client_id
    } = get_config()

    params = %{
      response_type: "code",
      client_id: client_id,
      redirect_uri: callback_url(conn),
      state: state,
      # TODO - make dynamic (accepting PRs!):
      scope: "openid profile email"
    }

    url = "https://#{auth_domain}/oauth2/authorize?" <> URI.encode_query(params)

    conn
    |> fetch_session()
    |> put_session("cognito_state", state)
    |> redirect!(url)
    |> halt()
  end

  def handle_callback!(%Plug.Conn{params: %{"state" => state}} = conn) do
    expected_state =
      conn
      |> fetch_session()
      |> get_session("cognito_state")

    conn =
      if state == expected_state do
        exchange_code_for_token(conn)
      else
        set_errors!(conn, error("bad_state", "State parameter doesn't match"))
      end

    conn
    |> fetch_session()
    |> delete_session("cognito_state")
  end

  def handle_callback!(conn) do
    set_errors!(conn, error("no_state", "Missing state param"))
  end

  defp exchange_code_for_token(%Plug.Conn{params: %{"code" => code}} = conn) do
    http_client = Application.get_env(:ueberauth_cognito, :__http_client, :hackney)

    jwt_verifier =
      Application.get_env(
        :ueberauth_cognito,
        :__jwt_verifier,
        Ueberauth.Strategy.Cognito.JwtUtilities
      )

    %{
      client_id: client_id,
      aws_region: aws_region,
      user_pool_id: user_pool_id
    } = get_config()

    case request_token(conn, code, http_client) do
      {:ok, token} ->
        case request_jwks(http_client) do
          {:ok, jwks} ->
            case jwt_verifier.verify(
                   token["id_token"],
                   jwks,
                   client_id,
                   aws_region,
                   user_pool_id
                 ) do
              {:ok, id_token} ->
                conn
                |> put_private(:cognito_token, token)
                |> put_private(:cognito_id_token, id_token)

              {:error, _} ->
                set_errors!(conn, error("bad_id_token", "Could not validate JWT id_token"))
            end

          {:error, _} ->
            set_errors!(conn, error("jwks_response", "Error fetching JWKs"))
        end

      {:error, _} ->
        set_errors!(conn, error("aws_response", "Non-200 error code from AWS"))
    end
  end

  defp exchange_code_for_token(conn) do
    set_errors!(conn, error("no_code", "Missing code param"))
  end

  defp request_jwks(http_client) do
    %{
      aws_region: aws_region,
      user_pool_id: user_pool_id
    } = get_config()

    response =
      http_client.request(
        :get,
        "https://cognito-idp.#{aws_region}.amazonaws.com/#{user_pool_id}/.well-known/jwks.json"
      )

    case response do
      {:ok, 200, _headers, ref} ->
        {:ok, body} = http_client.body(ref)
        {:ok, Jason.decode!(body)}

      _ ->
        {:error, :cannot_fetch_jwks}
    end
  end

  defp request_token(conn, code, http_client) do
    %{
      auth_domain: auth_domain,
      client_id: client_id,
      client_secret: client_secret
    } = get_config()

    auth = Base.encode64("#{client_id}:#{client_secret}")

    params = %{
      grant_type: "authorization_code",
      code: code,
      client_id: client_id,
      redirect_uri: callback_url(conn)
    }

    response =
      http_client.request(
        :post,
        "https://#{auth_domain}/oauth2/token",
        [
          {"content-type", "application/x-www-form-urlencoded"},
          {"authorization", "Basic #{auth}"}
        ],
        URI.encode_query(params)
      )

    case response do
      {:ok, 200, _headers, client_ref} ->
        {:ok, body} = http_client.body(client_ref)
        {:ok, Jason.decode!(body)}

      _ ->
        {:error, :cannot_fetch_tokens}
    end
  end

  def credentials(conn) do
    token = conn.private.cognito_token

    expires_at =
      if token["expires_in"] do
        System.system_time(:seconds) + token["expires_in"]
      end

    %Ueberauth.Auth.Credentials{
      token: token["access_token"],
      refresh_token: token["refresh_token"],
      expires: !!expires_at,
      expires_at: expires_at
    }
  end

  def uid(conn) do
    conn.private.cognito_id_token["cognito:username"]
  end

  def info(_conn) do
    %Ueberauth.Auth.Info{}
  end

  def extra(conn) do
    %Ueberauth.Auth.Extra{
      raw_info: conn.private.cognito_id_token
    }
  end

  def handle_cleanup!(conn) do
    conn
    |> put_private(:cognito_token, nil)
    |> put_private(:cognito_id_token, nil)
  end

  defp get_config do
    config = Application.get_env(:ueberauth, Ueberauth.Strategy.Cognito) || %{}

    Map.new([:auth_domain, :client_id, :client_secret, :user_pool_id, :aws_region], fn c ->
      {c, config_value(config[c])}
    end)
  end

  defp config_value(value) when is_binary(value), do: value
  defp config_value({m, f, a}), do: apply(m, f, a)
end
