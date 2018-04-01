defmodule Tortoise.Connection.TransmitterTest do
  use ExUnit.Case, async: true
  doctest Tortoise.Connection.Transmitter

  alias Tortoise.Connection.Transmitter

  setup context do
    {:ok, %{client_id: context.test}}
  end

  def setup_transmitter(context) do
    opts = [client_id: context.client_id]
    {:ok, _} = Transmitter.start_link(opts)
    {:ok, client_socket, server_socket} = Tortoise.TestTCPTunnel.new()
    Transmitter.handle_socket(context.test, client_socket)

    {:ok, %{client: client_socket, server: server_socket}}
  end

  test "life-cycle", context do
    assert {:ok, pid} = Transmitter.start_link(client_id: context.client_id)
    assert Process.alive?(pid)
    assert :ok = Transmitter.stop(pid)
    refute Process.alive?(pid)
  end
end
