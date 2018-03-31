defmodule Tortoise.Connection.InflightTest do
  use ExUnit.Case, async: true
  doctest Tortoise.Connection.Inflight

  alias Tortoise.Connection.Inflight

  setup context do
    {:ok, %{client_id: context.test}}
  end

  def setup_inflight(context) do
    {:ok, pid} = Inflight.start_link(client_id: context.client_id)
    {:ok, %{inflight_pid: pid}}
  end

  test "life-cycle", context do
    assert {:ok, pid} = Inflight.start_link(client_id: context.client_id)
    assert Process.alive?(pid)
    assert :ok = Inflight.stop(pid)
    refute Process.alive?(pid)
  end
end
