defmodule AlloyCi.RunnersTest do
  @moduledoc """
  """
  use AlloyCi.DataCase
  alias AlloyCi.{Runners, Repo}
  import AlloyCi.Factory
  import Mock

  setup do
    build = insert(:full_build)

    {:ok, %{build: build}}
  end

  describe "get_by_token/1" do
    test "it gets the correct runner" do
      runner = insert(:runner)
      result = Runners.get_by_token(runner.token)

      assert result.id == runner.id
    end

    test "it returns nil when runner not found" do
      result = Runners.get_by_token("invalid-token")

      assert result == nil
    end
  end

  describe "register_job/1" do
    test "it processes and starts the correct build", %{build: build} do
      runner = insert(:runner)
      with_mock Tentacat.Integrations.Installations, [get_token: fn(_, _) -> {:ok, %{"token" => "v1.1f699f1069f60xxx"}} end] do
        {:ok, result} = Runners.register_job(runner)

        assert result.id == build.id
        assert result.status == "running"
        assert result.runner_id == runner.id
      end
    end

    test "it returns correct status when no build is found", %{build: build} do
      runner = insert(:runner)
      Repo.delete!(build)
      {:no_build, result} = Runners.register_job(runner)

      assert result == nil
    end
  end
end
