defmodule AlloyCi.Runners do
  @moduledoc """
  """
  alias AlloyCi.{Builds, Project, Projects, Repo, Runner}

  @global_token Application.get_env(:alloy_ci, :runner_registration_token)

  def create(%{"token" => @global_token, "info" => runner_info} = params) do
    new_runner =
      Enum.into(%{global: true}, runner_params(params, runner_info))

    case save(new_runner) do
      {:ok, runner} -> runner
      {:error, _} -> nil
    end
  end

  def create(%{"token" => token, "info" => runner_info} = params) do
    with %Project{} = project <- Projects.get_by_token(token) do
      new_runner =
        %{
          global: false,
          project_id: project.id
        }
        |> Enum.into(runner_params(params, runner_info))

      case save(new_runner) do
        {:ok, runner} -> runner
        {:error, _} -> nil
      end
    else
      _ ->
        nil
    end
  end

  def save(params) do
    %Runner{}
    |> Runner.changeset(params)
    |> Repo.insert
  end

  def get_by_token(token) do
    Runner
    |> Repo.get_by(token: token)
  end

  def update_info(runner, params) do
    runner
    |> Runner.changeset(params)
    |> Repo.update()
  end

  def register_job(%{project_id: nil, tags: nil} = runner) do
    Builds.to_process()
    |> Builds.start_build(runner)
  end

  def register_job(%{project_id: nil, run_untagged: true} = runner) do
    Builds.to_process()
    |> Builds.start_build(runner)
  end

  def register_job(%{project_id: nil} = runner) do
    Builds.for_runner(runner)
    |> Builds.start_build(runner)
  end

  def register_job(%{project_id: project_id} = runner) do
    Builds.for_project(project_id)
    |> Builds.start_build(runner)
  end

  defp runner_params(params, runner_info) do
    tags =
      case String.split(params["tag_list"] || "", ", ") do
        [""] -> nil
        list -> list
      end

    %{
      active: true,
      architecture: runner_info["architecture"],
      description: params["description"],
      name: runner_info["name"],
      locked: params["locked"],
      platform: runner_info["platform"],
      run_untagged: params["run_untagged"],
      token: SecureRandom.urlsafe_base64(10),
      tags: tags,
      version: runner_info["version"]
    }
  end
end
