defmodule AlloyCi.Web.BadgeController do
  use AlloyCi.Web, :controller
  alias AlloyCi.Projects

  def index(conn, %{"project_id" => id, "ref" => ref}, _current_user, _claims) do
    badge = Projects.build_badge(id, ref)
    render(conn, "index.svg", badge: badge)
  end
end
