defmodule Tortoise.EventsTest do
  use ExUnit.Case, async: true

  setup context do
    {:ok, %{client_id: context.test, transport: Tortoise.Transport.Tcp}}
  end

  defp via_name(client_id) do
    Tortoise.Connection.via_name(client_id)
  end

  def run_setup(context, setup) when is_atom(setup) do
    context_update =
      case apply(__MODULE__, setup, [context]) do
        {:ok, update} -> update
        [{_, _} | _] = update -> update
        %{} = update -> update
      end

    Enum.into(context_update, context)
  end

  def setup_connection(context) do
    {:ok, client_socket, server_socket} = Tortoise.Integration.TestTCPTunnel.new()
    name = via_name(context.client_id)
    :ok = Tortoise.Registry.put_meta(name, :connecting)

    {:ok, %{client: client_socket, server: server_socket}}
  end

  describe "passive connection" do
    setup [:setup_connection]

    test "get connection", context do
      parent = self()

      child =
        spawn_link(fn ->
          send(parent, :ready)
          {:ok, connection} = Tortoise.Connection.connection(context.client_id)
          send(parent, {:received, connection})
          :timer.sleep(:infinity)
        end)

      # make sure the child process is ready and assert if it has
      # registered itself for a connection
      assert_receive :ready
      assert [:connection] = Registry.keys(Tortoise.Events, child)

      # dispatch the connection
      connection = {context.transport, context.client}
      :ok = Tortoise.Events.dispatch(context.client_id, :connection, connection)

      # the subscriber should receive the connection and unregister
      # itself from the connection event
      assert_receive {:received, ^connection}
      assert [] = Registry.keys(Tortoise.Events, child)
    end
  end

  describe "active connection" do
    setup [:setup_connection]

    test "get connection", context do
      client_id = context.client_id
      parent = self()

      child =
        spawn_link(fn ->
          send(parent, :ready)
          {:ok, connection} = Tortoise.Connection.connection(context.client_id, active: true)
          send(parent, {:received, connection})
          # later it should receive new sockets
          receive do
            {{Tortoise, ^client_id}, :connection, connection} ->
              send(parent, {:received, connection})
              :timer.sleep(:infinity)
          after
            500 ->
              send(parent, :timeout)
          end
        end)

      # make sure the child process is ready and assert if it has
      # registered itself for a connection
      assert_receive :ready
      assert [:connection] = Registry.keys(Tortoise.Events, child)

      # dispatch the connection
      connection = {context.transport, context.client}
      :ok = Tortoise.Events.dispatch(context.client_id, :connection, connection)

      # the subscriber should receive the connection and it should
      # still be registered for new connections
      assert_receive {:received, ^connection}
      assert [:connection] = Registry.keys(Tortoise.Events, child)

      context = run_setup(context, :setup_connection)
      new_connection = {context.transport, context.client}
      :ok = Tortoise.Events.dispatch(context.client_id, :connection, new_connection)
      assert_receive {:received, ^new_connection}
      assert [:connection] = Registry.keys(Tortoise.Events, child)
    end
  end

  describe "ping responses" do
    test "receive ping responses", context do
      client_id1 = Atom.to_string(context.client_id)
      client_id2 = client_id1 <> "2"
      client_id3 = client_id1 <> "3"

      # register retrieval of ping requests from 1 and 2
      assert {:ok, owner} = Tortoise.Events.register(client_id1, :ping_response)
      assert {:ok, ^owner} = Tortoise.Events.register(client_id2, :ping_response)

      # dispatch ping responses; expect from 1 and 2, but not 3
      Tortoise.Events.dispatch(client_id1, :ping_response, 500)
      Tortoise.Events.dispatch(client_id2, :ping_response, 500)
      Tortoise.Events.dispatch(client_id3, :ping_response, 500)
      assert_receive {{Tortoise, ^client_id1}, :ping_response, 500}
      assert_receive {{Tortoise, ^client_id2}, :ping_response, 500}
      refute_receive {{Tortoise, ^client_id3}, :ping_response, 500}

      # unregister 2, and register 3
      Tortoise.Events.unregister(client_id2, :ping_response)
      assert {:ok, ^owner} = Tortoise.Events.register(client_id3, :ping_response)

      # dispatch ping responses, and expect from 1 and 3, not 2
      Tortoise.Events.dispatch(client_id1, :ping_response, 500)
      Tortoise.Events.dispatch(client_id2, :ping_response, 500)
      Tortoise.Events.dispatch(client_id3, :ping_response, 500)
      assert_receive {{Tortoise, ^client_id1}, :ping_response, 500}
      refute_receive {{Tortoise, ^client_id2}, :ping_response, 500}
      assert_receive {{Tortoise, ^client_id3}, :ping_response, 500}
    end
  end
end
