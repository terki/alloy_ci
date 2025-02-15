defmodule AlloyCi.Projects do
  @moduledoc """
  The boundary for the Projects system.
  """
  alias AlloyCi.{Accounts, Pipeline, Pipelines, Project, ProjectPermission, Repo, User}
  import Ecto.Query

  @github_api Application.get_env(:alloy_ci, :github_api)

  @spec all(map()) :: {[Project.t()], Kerosene.t()}
  def all(params) do
    Project |> order_by(desc: :updated_at) |> Repo.paginate(params)
  end

  @spec build_badge(binary(), binary()) :: %{color: any(), status: any()}
  def build_badge(id, ref) do
    status = last_status(%{id: String.to_integer(id)}, ref)

    colors = %{
      "success" => "#4c1",
      "failed" => "#e05d44",
      "running" => "#dfb317",
      "pending" => "#dfb317",
      "cancelled" => "#9f9f9f",
      "unknown" => "#9f9f9f"
    }

    %{color: colors[status], status: status}
  end

  @spec can_access?(any(), any()) :: boolean()
  def can_access?(id, user) do
    with %Project{} = project <- get(id),
         true <- project.private,
         %ProjectPermission{} <- get_project_permission(id, user) do
      # Project is private, but user can access it
      true
    else
      false ->
        # Project is not private, so return true
        true

      nil ->
        # Project is private and user does not have permission to access it
        false
    end
  end

  @spec can_manage?(pos_integer() | nil, User.t()) :: boolean()
  def can_manage?(nil, _), do: false

  def can_manage?(id, user) do
    permission = get_project_permission(id, user)

    case permission do
      %ProjectPermission{} ->
        true

      _ ->
        false
    end
  end

  @spec create_project(nil | keyword() | map(), User.t()) :: any()
  def create_project(params, user) do
    installation_id =
      @github_api.installation_id_for(
        System.get_env("GITHUB_TARGET_UID") || Accounts.github_auth(user).uid
      )

    with true <- Accounts.installed_on_owner?(params["owner_id"]),
         %{"content" => _} <-
           @github_api.alloy_ci_config(%{name: params["name"], owner: params["owner"]}, %{
             sha: "master",
             installation_id: installation_id
           }) do
      Repo.transaction(fn ->
        changeset =
          Project.changeset(
            %Project{},
            Enum.into(params, %{"token" => SecureRandom.urlsafe_base64(10)})
          )

        with {:ok, project} <- Repo.insert(changeset) do
          permissions_changeset =
            ProjectPermission.changeset(%ProjectPermission{}, %{
              project_id: project.id,
              repo_id: project.repo_id,
              user_id: user.id
            })

          case Repo.insert(permissions_changeset) do
            {:ok, _} -> project
            {:error, changeset} -> changeset |> Repo.rollback()
          end
        else
          {:error, changeset} -> changeset |> Repo.rollback()
        end
      end)
    else
      false ->
        {:missing_installation, nil}

      _ ->
        {:missing_config, nil}
    end
  end

  @spec delete_by(any(), User.t()) :: {:error, any()} | {:ok, Project.t()}
  def delete_by(id, user) do
    with {:ok, project} <- get_by(id, user),
         :ok <- Pipelines.delete_where(project_id: id),
         :ok <- purge_permissions(id) do
      Repo.delete(project)
    end
  end

  @spec delete_by(any()) :: {:error, any()} | {:ok, Project.t()}
  def delete_by(id) do
    with :ok <- Pipelines.delete_where(project_id: id),
         :ok <- purge_permissions(id) do
      Project |> Repo.get(id) |> Repo.delete()
    end
  end

  @spec get(any()) :: Project.t()
  def get(id), do: Project |> Repo.get(id)

  @spec get_by(any(), User.t()) :: {:error, nil} | {:ok, Project.t()}
  def get_by(id, user) do
    permission =
      id
      |> get_project_permission(user)
      |> Repo.preload(:project)

    case permission do
      %ProjectPermission{} ->
        {:ok, permission.project}

      _ ->
        {:error, nil}
    end
  end

  @spec get_by(any(), User.t(), [{:preload, any()}, ...]) :: {:error, nil} | {:ok, Project.t()}
  def get_by(id, user, preload: subject) do
    permission =
      id
      |> get_project_permission(user)
      |> Repo.preload(:project)

    case permission do
      %ProjectPermission{} ->
        project = permission.project |> Repo.preload(subject)
        {:ok, project}

      _ ->
        {:error, nil}
    end
  end

  @spec get_by([{:repo_id, any()} | {:token, any()}, ...]) :: {:error, nil} | {:ok, Project.t()}
  def get_by(repo_id: id) do
    case Project |> Repo.get_by(repo_id: id) do
      nil ->
        {:error, nil}

      project ->
        {:ok, project}
    end
  end

  def get_by(token: token) do
    case Project |> Repo.get_by(token: token) do
      nil ->
        {:error, nil}

      project ->
        {:ok, project}
    end
  end

  @spec last_status(Project.t(), binary()) :: binary()
  def last_status(project, ref) do
    query =
      from(
        p in "pipelines",
        where: [project_id: ^project.id, ref: ^"refs/heads/#{ref}"],
        order_by: [desc: :inserted_at],
        limit: 1,
        select: p.status
      )

    Repo.one(query) || "unknown"
  end

  @spec last_statuses(any()) :: map()
  def last_statuses(projects) do
    ids = projects |> Enum.map(fn p -> p.id end)

    query =
      from(
        p in "pipelines",
        where: p.project_id in ^ids,
        order_by: [desc: :inserted_at],
        distinct: p.project_id,
        select: {p.project_id, p.status}
      )

    query |> Repo.all() |> Map.new()
  end

  @spec latest(User.t()) :: [Project.t()]
  def latest(user) do
    query =
      from(
        p in Project,
        join: pp in "project_permissions",
        on: p.id == pp.project_id,
        where: pp.user_id == ^user.id,
        order_by: [desc: p.updated_at],
        limit: 5,
        select: %{id: p.id, name: p.name}
      )

    Repo.all(query)
  end

  @spec paginated_for(User.t(), map()) :: {Project.t(), Kerosene.t()}
  def paginated_for(user, params) do
    query =
      from(
        p in Project,
        join: pp in "project_permissions",
        on: p.id == pp.project_id,
        where: pp.user_id == ^user.id,
        order_by: [desc: p.updated_at],
        select: p
      )

    Repo.paginate(query, params)
  end

  @spec private?(any()) :: boolean()
  def private?(id) do
    Project
    |> where(id: ^id)
    |> select([p], p.private)
    |> Repo.one()
  end

  @spec repo_and_project(any(), any()) :: {:error, nil} | {:ok, any()}
  def repo_and_project(repo_id, existing_ids) do
    result =
      existing_ids
      |> Enum.reject(fn {r_id, _} ->
        r_id != repo_id
      end)

    if Enum.empty?(result) do
      {:error, nil}
    else
      {:ok, List.first(result)}
    end
  end

  @spec show_by(any(), User.t(), any()) ::
          {:error, nil} | {:ok, {Project.t(), Pipeline.t(), Kerosene.t()}}
  def show_by(id, user, params) do
    project = get(id)

    with %Project{} <- project,
         true <- project.private,
         %ProjectPermission{} <- get_project_permission(id, user) do
      {pipelines, kerosene} = Pipelines.paginated(id, params)
      {:ok, {project, pipelines, kerosene}}
    else
      false ->
        {pipelines, kerosene} = Pipelines.paginated(id, params)
        {:ok, {project, pipelines, kerosene}}

      nil ->
        {:error, nil}
    end
  end

  @spec touch(any()) :: {:error, any()} | {:ok, Project.t()}
  def touch(id) do
    Project
    |> Repo.get(id)
    |> Project.changeset()
    |> Repo.update(force: true)
  end

  @spec update(Project.t(), map()) :: {:error, any()} | {:ok, Project.t()}
  def update(project, params) do
    params =
      with {:ok, secret_vars} <- Poison.decode(params["secret_variables"] || "") do
        Map.merge(params, %{"secret_variables" => secret_vars})
      else
        _ ->
          Map.merge(params, %{"secret_variables" => nil})
      end

    params =
      case params["tags"] do
        # if all tags are deleted on the frontend, params will not contain the
        # tags element, so we set it explicitly here
        nil ->
          Map.merge(params, %{"tags" => nil})

        _ ->
          params
      end

    project
    |> Project.changeset(params)
    |> Repo.update()
  end

  ###################
  # Private functions
  ###################
  defp get_project_permission(id, user) do
    if user do
      ProjectPermission
      |> Repo.get_by(project_id: id, user_id: user.id)
    end
  end

  defp purge_permissions(project_id) do
    query =
      ProjectPermission
      |> where(project_id: ^project_id)

    case Repo.delete_all(query) do
      {_, nil} -> :ok
      _ -> :error
    end
  end
end
