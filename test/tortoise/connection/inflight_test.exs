defmodule Tortoise.Connection.InflightTest do
  use ExUnit.Case, async: true
  doctest Tortoise.Connection.Inflight

  alias Tortoise.Connection.Inflight

  setup context do
    {:ok, %{client_id: context.test}}
  end

  def setup_connection(context) do
    {:ok, client_socket, server_socket} = Tortoise.Integration.TestTCPTunnel.new()
    connection = {Tortoise.Transport.Tcp, client_socket}
    key = Tortoise.Registry.via_name(Tortoise.Connection, context.client_id)
    Tortoise.Registry.put_meta(key, connection)
    {:ok, %{client: client_socket, server: server_socket}}
  end

  def setup_inflight(context) do
    {:ok, pid} = Inflight.start_link(client_id: context.client_id)
    {:ok, %{inflight_pid: pid}}
  end

  describe "life-cycle" do
    setup [:setup_connection]

    test "start/stop", context do
      assert {:ok, pid} = Inflight.start_link(client_id: context.client_id)
      assert Process.alive?(pid)
      assert :ok = Inflight.stop(pid)
      refute Process.alive?(pid)
    end
  end
end
