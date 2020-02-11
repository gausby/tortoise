defmodule TortoiseTest do
  use ExUnit.Case
  doctest Tortoise

  alias Tortoise.Package
  alias Tortoise.Connection.Inflight

  setup context do
    {:ok, %{client_id: context.test, transport: Tortoise.Transport.Tcp}}
  end

  def setup_connection(context) do
    {:ok, client_socket, server_socket} = Tortoise.Integration.TestTCPTunnel.new()
    name = Tortoise.Connection.via_name(context.client_id)
    connection = {context.transport, client_socket}
    :ok = Tortoise.Registry.put_meta(name, connection)
    {:ok, %{client: client_socket, server: server_socket, connection: connection}}
  end

  def setup_inflight(context) do
    opts = [client_id: context.client_id, parent: self()]
    {:ok, pid} = Inflight.start_link(opts)
    :ok = Inflight.update_connection(pid, context.connection)
    {:ok, %{inflight_pid: pid}}
  end

  describe "publish/4" do
    setup [:setup_connection, :setup_inflight]

    test "publish qos=0", context do
      assert :ok = Tortoise.publish(context.client_id, "foo/bar")
      assert {:ok, data} = :gen_tcp.recv(context.server, 0, 500)
      assert %Package.Publish{topic: "foo/bar", qos: 0, payload: nil} = Package.decode(data)
    end

    test "publish qos=1", context do
      assert {:ok, _ref} = Tortoise.publish(context.client_id, "foo/bar", nil, qos: 1)
      assert {:ok, data} = :gen_tcp.recv(context.server, 0, 500)
      assert %Package.Publish{topic: "foo/bar", qos: 1, payload: nil} = Package.decode(data)
    end

    test "publish qos=1 with user defined callbacks", %{client_id: client_id} = context do
      parent = self()

      transforms = [
        publish: fn %type{properties: properties}, [:init] = state ->
          send(parent, {:callback, {type, properties}, state})
          {:ok, properties, [type | state]}
        end,
        puback: fn %type{properties: properties}, state ->
          send(parent, {:callback, {type, properties}, state})
          {:ok, [type | state]}
        end
      ]

      assert {:ok, publish_ref} =
               Tortoise.publish(context.client_id, "foo/bar", nil,
                 qos: 1,
                 transforms: {transforms, [:init]}
               )

      assert {:ok, data} = :gen_tcp.recv(context.server, 0, 500)

      assert %Package.Publish{identifier: id, topic: "foo/bar", qos: 1, payload: nil} =
               Package.decode(data)

      :ok = Inflight.update(client_id, {:received, %Package.Puback{identifier: id}})
      # check the internal transform state
      assert_receive {:callback, {Package.Publish, []}, [:init]}
      assert_receive {:callback, {Package.Puback, []}, [Package.Publish, :init]}
    end

    test "publish qos=2", context do
      assert {:ok, _ref} = Tortoise.publish(context.client_id, "foo/bar", nil, qos: 2)
      assert {:ok, data} = :gen_tcp.recv(context.server, 0, 500)
      assert %Package.Publish{topic: "foo/bar", qos: 2, payload: nil} = Package.decode(data)
    end

    test "publish qos=2 with custom callbacks", %{client_id: client_id} = context do
      parent = self()

      transforms = [
        publish: fn %type{properties: properties}, [:init] = state ->
          send(parent, {:callback, {type, properties}, state})
          {:ok, [{:user_property, {"foo", "bar"}} | properties], [type | state]}
        end,
        pubrec: fn %type{properties: properties}, state ->
          send(parent, {:callback, {type, properties}, state})
          {:ok, [type | state]}
        end,
        pubrel: fn %type{properties: properties}, state ->
          send(parent, {:callback, {type, properties}, state})
          properties = [{:user_property, {"hello", "world"}} | properties]
          {:ok, properties, [type | state]}
        end,
        pubcomp: fn %type{properties: properties}, state ->
          send(parent, {:callback, {type, properties}, state})
          {:ok, [type | state]}
        end
      ]

      assert {:ok, publish_ref} =
               Tortoise.publish(context.client_id, "foo/bar", nil,
                 qos: 2,
                 transforms: {transforms, [:init]}
               )

      assert {:ok, data} = :gen_tcp.recv(context.server, 0, 500)

      assert %Package.Publish{
               identifier: id,
               topic: "foo/bar",
               qos: 2,
               payload: nil,
               properties: [user_property: {"foo", "bar"}]
             } = Package.decode(data)

      :ok = Inflight.update(context.client_id, {:received, %Package.Pubrec{identifier: id}})

      pubrel = %Package.Pubrel{identifier: id}
      :ok = Inflight.update(client_id, {:dispatch, pubrel})

      assert {:ok, data} = :gen_tcp.recv(context.server, 0, 500)

      expected_pubrel = %Package.Pubrel{
        pubrel
        | properties: [user_property: {"hello", "world"}]
      }

      assert expected_pubrel == Package.decode(data)

      :ok = Inflight.update(client_id, {:received, %Package.Pubcomp{identifier: id}})

      assert_receive {{Tortoise, ^client_id}, {Package.Publish, ^publish_ref}, :ok}
      # check the internal state of the transform; in the test we add
      # the type of the package to the state, which we have defied as
      # a list:
      assert_receive {:callback, {Package.Publish, []}, [:init]}
      assert_receive {:callback, {Package.Pubrec, []}, [Package.Publish | _]}
      assert_receive {:callback, {Package.Pubrel, []}, [Package.Pubrec | _]}
      expected_state = [Package.Pubrel, Package.Pubrec, Package.Publish, :init]
      assert_receive {:callback, {Package.Pubcomp, []}, ^expected_state}
    end
  end

  describe "publish_sync/4" do
    setup [:setup_connection, :setup_inflight]

    test "publish qos=0", context do
      assert :ok = Tortoise.publish_sync(context.client_id, "foo/bar")
      assert {:ok, data} = :gen_tcp.recv(context.server, 0, 500)
      assert %Package.Publish{topic: "foo/bar", qos: 0, payload: nil} = Package.decode(data)
    end

    test "publish qos=1", context do
      client_id = context.client_id
      parent = self()

      spawn_link(fn ->
        :ok = Tortoise.publish_sync(context.client_id, "foo/bar", nil, qos: 1)
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
        :ok = Tortoise.publish_sync(client_id, "foo/bar", nil, qos: 2)
        send(parent, :done)
      end)

      assert {:ok, data} = :gen_tcp.recv(context.server, 0, 500)

      assert %Package.Publish{identifier: id, topic: "foo/bar", qos: 2, payload: nil} =
               Package.decode(data)

      :ok = Inflight.update(client_id, {:received, %Package.Pubrec{identifier: id}})
      # respond with a pubrel
      pubrel = %Package.Pubrel{identifier: id}
      :ok = Inflight.update(client_id, {:dispatch, pubrel})
      assert {:ok, data} = :gen_tcp.recv(context.server, 0, 500)
      assert ^pubrel = Package.decode(data)

      :ok = Inflight.update(client_id, {:received, %Package.Pubcomp{identifier: id}})
      assert_receive :done
    end
  end
end
