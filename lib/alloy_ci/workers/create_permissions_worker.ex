defmodule AlloyCi.Workers.CreatePermissionsWorker do
  @moduledoc """
  This worker takes care of creating the project permissions for newly created
  users. If the user has access to a project that has already been added to
  AlloyCI, it will be added to the list of projects to which they already have
  access.
  """
  alias AlloyCi.{ProjectPermission, Repo}
  import AlloyCi.ProjectPermission, only: [repo_ids: 0]
  import Ecto.Query

  @github_api Application.get_env(:alloy_ci, :github_api)

  @spec perform({any(), any()}) :: {:error, any()} | {:ok, ProjectPermission.t()}
  def perform({user_id, token}) do
    user_repo_ids =
      token
      |> @github_api.fetch_repos()
      |> Enum.map(& &1["id"])

    permission_ids = MapSet.intersection(MapSet.new(user_repo_ids), MapSet.new(repo_ids()))

    Repo.transaction(fn ->
      Enum.each(permission_ids, fn id ->
        project_id = Repo.one(from p in ProjectPermission, where: p.repo_id == ^id, limit: 1).project_id
        params = %{user_id: user_id, project_id: project_id, repo_id: id}

        %ProjectPermission{}
        |> ProjectPermission.changeset(params)
        |> Repo.insert(on_conflict: :nothing)
      end)
    end)
  end
end
