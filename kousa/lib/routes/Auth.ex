defmodule Kousa.Auth do
  import Plug.Conn
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/web" do
    url =
      "https://github.com/login/oauth/authorize?client_id=" <>
        Application.get_env(:kousa, :client_id) <>
        "&state=web" <>
        "&redirect_uri=" <>
        Application.get_env(:kousa, :api_url) <>
        "/auth/github/callback&scope=read:user,user:email"

    Kousa.Redirect.redirect(conn, url)
  end

  get "/" do
    url =
      "https://github.com/login/oauth/authorize?client_id=" <>
        Application.get_env(:kousa, :client_id) <>
        "&redirect_uri=" <>
        Application.get_env(:kousa, :api_url) <>
        "/auth/github/callback&scope=read:user,user:email"

    Kousa.Redirect.redirect(conn, url)
  end

  get "/callback" do
    conn_with_qp = fetch_query_params(conn)
    code = conn_with_qp.query_params["code"]

    base_url =
      if Map.get(conn_with_qp.query_params, "state", "") == "web",
        do: Application.fetch_env!(:kousa, :web_url),
        else: "http://localhost:54321"

    case HTTPoison.post(
           "https://github.com/login/oauth/access_token",
           Poison.encode!(%{
             "code" => code,
             "client_id" => Application.get_env(:kousa, :client_id),
             "client_secret" => Application.get_env(:kousa, :client_secret)
           }),
           [
             {"Content-Type", "application/json"},
             {"Accept", "application/json"}
           ]
         ) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        json = Poison.decode!(body)

        case json do
          %{"error" => "bad_verification_code"} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(
              500,
              Poison.encode!(%{
                "error" => "code expired, try to login again"
              })
            )

          %{"access_token" => accessToken} ->
            user = Kousa.Github.get_user(accessToken)

            if user do
              try do
                db_user =
                  case Kousa.Data.User.find_or_create(user, accessToken) do
                    {:find, uu} ->
                      uu

                    {:create, uu} ->
                      Kousa.BL.User.load_followers(accessToken, uu.id)
                      uu
                  end

                if not is_nil(db_user.reasonForBan) do
                  conn
                  |> Kousa.Redirect.redirect(
                    base_url <>
                      "/?error=" <>
                      URI.encode(
                        "your account got banned, if you think this was a mistake, please send me an email at benawadapps@gmail.com"
                      )
                  )
                else
                  conn
                  |> Kousa.Redirect.redirect(
                    base_url <>
                      "/?accessToken=" <>
                      Kousa.AccessToken.generate_and_sign!(%{"userId" => db_user.id}) <>
                      "&refreshToken=" <>
                      Kousa.RefreshToken.generate_and_sign!(%{
                        "userId" => db_user.id,
                        "tokenVersion" => db_user.tokenVersion
                      })
                  )
                end
              rescue
                e in RuntimeError ->
                  conn
                  |> Kousa.Redirect.redirect(
                    base_url <>
                      "/?error=" <>
                      URI.encode(e.message)
                  )
              end
            else
              conn
              |> Kousa.Redirect.redirect(
                base_url <>
                  "/?error=" <>
                  URI.encode(
                    "something went wrong fetching the user, tell ben to check the server logs"
                  )
              )
            end

          resp ->
            conn
            |> Kousa.Redirect.redirect(
              base_url <>
                "/?error=" <>
                URI.encode(resp)
            )
        end

      x ->
        IO.inspect(x)

        conn
        |> Kousa.Redirect.redirect(
          base_url <>
            "/?error=" <>
            URI.encode("something went wrong, tell ben to check the server logs")
        )
    end
  end
end
