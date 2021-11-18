defmodule TortoiseTest do
  use ExUnit.Case
  doctest Tortoise311

  alias Tortoise311.Package
  alias Tortoise311.Connection.Inflight

  setup context do
    {:ok, %{client_id: context.test, transport: Tortoise311.Transport.Tcp}}
  end

  def setup_connection(context) do
    {:ok, client_socket, server_socket} = Tortoise311.Integration.TestTCPTunnel.new()
    name = Tortoise311.Connection.via_name(context.client_id)
    :ok = Tortoise311.Registry.put_meta(name, {context.transport, client_socket})
    {:ok, %{client: client_socket, server: server_socket}}
  end

  def setup_inflight(context) do
    opts = [client_id: context.client_id]
    {:ok, pid} = Inflight.start_link(opts)
    {:ok, %{inflight_pid: pid}}
  end

  describe "publish/4" do
    setup [:setup_connection, :setup_inflight]

    test "publish qos=0", context do
      assert :ok = Tortoise311.publish(context.client_id, "foo/bar")
      assert {:ok, data} = :gen_tcp.recv(context.server, 0, 500)
      assert %Package.Publish{topic: "foo/bar", qos: 0, payload: nil} = Package.decode(data)
    end

    test "publish qos=1", context do
      assert {:ok, _ref} = Tortoise311.publish(context.client_id, "foo/bar", nil, qos: 1)
      assert {:ok, data} = :gen_tcp.recv(context.server, 0, 500)
      assert %Package.Publish{topic: "foo/bar", qos: 1, payload: nil} = Package.decode(data)
    end

    test "publish qos=2", context do
      assert {:ok, _ref} = Tortoise311.publish(context.client_id, "foo/bar", nil, qos: 2)
      assert {:ok, data} = :gen_tcp.recv(context.server, 0, 500)
      assert %Package.Publish{topic: "foo/bar", qos: 2, payload: nil} = Package.decode(data)
    end
  end

  describe "publish_sync/4" do
    setup [:setup_connection, :setup_inflight]

    test "publish qos=0", context do
      assert :ok = Tortoise311.publish_sync(context.client_id, "foo/bar")
      assert {:ok, data} = :gen_tcp.recv(context.server, 0, 500)
      assert %Package.Publish{topic: "foo/bar", qos: 0, payload: nil} = Package.decode(data)
    end

    test "publish qos=1", context do
      client_id = context.client_id
      parent = self()

      spawn_link(fn ->
        :ok = Tortoise311.publish_sync(context.client_id, "foo/bar", nil, qos: 1)
        send(parent, :done)
      end)

      assert {:ok, data} = :gen_tcp.recv(context.server, 0, 500)

      assert %Package.Publish{identifier: id, topic: "foo/bar", qos: 1, payload: nil} =
               Package.decode(data)

      :ok = Inflight.update(client_id, {:received, %Package.Puback{identifier: id}})
      assert_receive :done
    end

    test "publish qos=2", context do
      client_id = context.client_id
      parent = self()

      spawn_link(fn ->
        :ok = Tortoise311.publish_sync(client_id, "foo/bar", nil, qos: 2)
        send(parent, :done)
      end)

      assert {:ok, data} = :gen_tcp.recv(context.server, 0, 500)

      assert %Package.Publish{identifier: id, topic: "foo/bar", qos: 2, payload: nil} =
               Package.decode(data)

      :ok = Inflight.update(client_id, {:received, %Package.Pubrec{identifier: id}})
      assert {:ok, data} = :gen_tcp.recv(context.server, 0, 500)
      assert %Package.Pubrel{identifier: ^id} = Package.decode(data)

      :ok = Inflight.update(client_id, {:received, %Package.Pubcomp{identifier: id}})
      assert_receive :done
    end
  end
end
