defmodule Tortoise.Connection.InflightTest do
  use ExUnit.Case, async: true
  doctest Tortoise.Connection.Inflight

  alias Tortoise.Package
  alias Tortoise.Connection.Inflight

  setup context do
    {:ok, %{client_id: context.test}}
  end

  def setup_connection(context) do
    {:ok, client_socket, server_socket} = Tortoise.Integration.TestTCPTunnel.new()
    connection = {Tortoise.Transport.Tcp, client_socket}
    key = Tortoise.Registry.via_name(Tortoise.Connection, context.client_id)
    Tortoise.Registry.put_meta(key, connection)
    Tortoise.Events.dispatch(context.client_id, :connection, connection)
    {:ok, Map.merge(context, %{client: client_socket, server: server_socket})}
  end

  defp drop_connection(%{server: server} = context) do
    :ok = :gen_tcp.close(server)
    :ok = Tortoise.Events.dispatch(context.client_id, :status, :down)
    {:ok, Map.drop(context, [:client, :server])}
  end

  def setup_inflight(context) do
    {:ok, pid} = Inflight.start_link(client_id: context.client_id, parent: self())
    {:ok, %{inflight_pid: pid}}
  end

  describe "life-cycle" do
    setup [:setup_connection]

    test "start/stop", context do
      assert {:ok, pid} = Inflight.start_link(client_id: context.client_id, parent: self())
      assert Process.alive?(pid)
      assert :ok = Inflight.stop(pid)
      refute Process.alive?(pid)
    end
  end

  describe "Publish with QoS=1" do
    setup [:setup_connection, :setup_inflight]

    test "incoming publish QoS=1", %{client_id: client_id} = context do
      publish = %Package.Publish{identifier: 1, topic: "foo", qos: 1}
      :ok = Inflight.track(client_id, {:incoming, publish})
      assert {:ok, puback} = :gen_tcp.recv(context.server, 0, 500)
      assert %Package.Puback{identifier: 1} = Package.decode(puback)
    end

    test "outgoing publish QoS=1", %{client_id: client_id} = context do
      publish = %Package.Publish{identifier: 1, topic: "foo", qos: 1}
      {:ok, ref} = Inflight.track(client_id, {:outgoing, publish})
      assert {:ok, package} = :gen_tcp.recv(context.server, 0, 500)
      assert ^publish = Package.decode(package)

      # drop and reestablish the connection
      {:ok, context} = drop_connection(context)
      {:ok, context} = setup_connection(context)

      # the inflight process should now re-transmit the publish
      assert {:ok, package} = :gen_tcp.recv(context.server, 0, 500)
      publish = %Package.Publish{publish | dup: true}
      assert ^publish = Package.decode(package)

      # simulate that we receive a puback from the server
      Inflight.update(client_id, {:received, %Package.Puback{identifier: 1}})

      # the calling process should get a result response
      assert_receive {{Tortoise, ^client_id}, {Package.Publish, ^ref}, :ok}
    end
  end

  describe "Publish with QoS=2" do
    setup [:setup_connection, :setup_inflight]

    test "incoming publish QoS=2", %{client_id: client_id} = context do
      publish = %Package.Publish{identifier: 1, topic: "foo", qos: 2}
      :ok = Inflight.track(client_id, {:incoming, publish})
      assert {:ok, pubrec} = :gen_tcp.recv(context.server, 0, 500)
      assert %Package.Pubrec{identifier: 1} = Package.decode(pubrec)

      # drop and reestablish the connection
      {:ok, context} = drop_connection(context)
      {:ok, context} = setup_connection(context)

      # now we should receive the same pubrec message
      assert {:ok, ^pubrec} = :gen_tcp.recv(context.server, 0, 500)

      # simulate that we receive a pubrel from the server
      Inflight.update(client_id, {:received, %Package.Pubrel{identifier: 1}})

      assert {:ok, pubcomp} = :gen_tcp.recv(context.server, 0, 500)
      assert %Package.Pubcomp{identifier: 1} = Package.decode(pubcomp)
    end

    test "outgoing publish QoS=2", %{client_id: client_id} = context do
      publish = %Package.Publish{identifier: 1, topic: "foo", qos: 2}
      {:ok, ref} = Inflight.track(client_id, {:outgoing, publish})

      # we should transmit the publish
      assert {:ok, package} = :gen_tcp.recv(context.server, 0, 500)
      assert ^publish = Package.decode(package)
      # drop and reestablish the connection
      {:ok, context} = drop_connection(context)
      {:ok, context} = setup_connection(context)
      # the publish should get re-transmitted
      publish = %Package.Publish{publish | dup: true}
      assert {:ok, package} = :gen_tcp.recv(context.server, 0, 500)
      assert ^publish = Package.decode(package)

      # simulate that we receive a pubrel from the server
      Inflight.update(client_id, {:received, %Package.Pubrec{identifier: 1}})

      # we should send the pubrel package
      assert {:ok, pubrel} = :gen_tcp.recv(context.server, 0, 500)
      assert %Package.Pubrel{identifier: 1} = Package.decode(pubrel)
      # drop and reestablish the connection
      {:ok, context} = drop_connection(context)
      {:ok, context} = setup_connection(context)
      # re-transmit the pubrel
      assert {:ok, ^pubrel} = :gen_tcp.recv(context.server, 0, 500)

      # When we receive the pubcomp message we should respond the caller
      Inflight.update(client_id, {:received, %Package.Pubcomp{identifier: 1}})
      assert_receive {{Tortoise, ^client_id}, {Package.Publish, ^ref}, :ok}
    end
  end

  describe "Subscription" do
    setup [:setup_connection, :setup_inflight]

    test "subscription", %{client_id: client_id} = context do
      opts = [no_local: false, retain_as_published: false, retain_handling: 1]

      subscribe = %Package.Subscribe{
        identifier: 1,
        topics: [
          {"foo", [{:qos, 0} | opts]},
          {"bar", [{:qos, 1} | opts]},
          {"baz", [{:qos, 2} | opts]}
        ]
      }

      {:ok, ref} = Inflight.track(client_id, {:outgoing, subscribe})

      # send the subscribe package
      assert {:ok, package} = :gen_tcp.recv(context.server, 0, 500)
      assert ^subscribe = Package.decode(package)
      # drop and reestablish the connection
      {:ok, context} = drop_connection(context)
      {:ok, context} = setup_connection(context)
      # re-transmit the subscribe package
      assert {:ok, ^package} = :gen_tcp.recv(context.server, 0, 500)

      # when receiving the suback we should respond to the caller
      suback = %Package.Suback{
        identifier: 1,
        acks: [{:ok, 0}, {:ok, 1}, {:ok, 2}]
      }

      Inflight.update(client_id, {:received, suback})

      assert_receive {{Tortoise, ^client_id}, {Package.Subscribe, ^ref}, _}
    end
  end

  describe "Unsubscribe" do
    setup [:setup_connection, :setup_inflight]

    test "unsubscribe", %{client_id: client_id} = context do
      unsubscribe = %Package.Unsubscribe{
        identifier: 1,
        topics: ["foo", "bar", "baz"]
      }

      {:ok, ref} = Inflight.track(client_id, {:outgoing, unsubscribe})

      # send the unsubscribe package
      assert {:ok, package} = :gen_tcp.recv(context.server, 0, 500)
      assert ^unsubscribe = Package.decode(package)
      # drop and reestablish the connection
      {:ok, context} = drop_connection(context)
      {:ok, context} = setup_connection(context)
      # re-transmit the subscribe package
      assert {:ok, ^package} = :gen_tcp.recv(context.server, 0, 500)

      # when receiving the suback we should respond to the caller
      Inflight.update(client_id, {:received, %Package.Unsuback{identifier: 1}})

      assert_receive {{Tortoise, ^client_id}, {Package.Unsubscribe, ^ref}, _}
    end
  end

  describe "message ordering" do
    setup [:setup_connection, :setup_inflight]

    test "publish should be retransmitted in the same order", context do
      client_id = context.client_id
      publish1 = %Package.Publish{identifier: 250, topic: "foo", qos: 1}
      publish2 = %Package.Publish{identifier: 500, topic: "foo", qos: 1}
      publish3 = %Package.Publish{identifier: 100, topic: "foo", qos: 1}

      {:ok, _} = Inflight.track(client_id, {:outgoing, publish1})
      {:ok, _} = Inflight.track(client_id, {:outgoing, publish2})
      {:ok, _} = Inflight.track(client_id, {:outgoing, publish3})

      expected = Package.encode(publish1) |> IO.iodata_to_binary()
      assert {:ok, ^expected} = :gen_tcp.recv(context.server, byte_size(expected), 500)
      expected = Package.encode(publish2) |> IO.iodata_to_binary()
      assert {:ok, ^expected} = :gen_tcp.recv(context.server, byte_size(expected), 500)
      expected = Package.encode(publish3) |> IO.iodata_to_binary()
      assert {:ok, ^expected} = :gen_tcp.recv(context.server, byte_size(expected), 500)

      # drop and reestablish the connection
      {:ok, context} = drop_connection(context)
      {:ok, context} = setup_connection(context)

      # the in flight manager should now re-transmit the publish
      # messages in the same order they arrived
      publish1 = %Package.Publish{publish1 | dup: true}
      publish2 = %Package.Publish{publish2 | dup: true}
      publish3 = %Package.Publish{publish3 | dup: true}

      expected = Package.encode(publish1) |> IO.iodata_to_binary()
      assert {:ok, ^expected} = :gen_tcp.recv(context.server, byte_size(expected), 500)
      expected = Package.encode(publish2) |> IO.iodata_to_binary()
      assert {:ok, ^expected} = :gen_tcp.recv(context.server, byte_size(expected), 500)
      expected = Package.encode(publish3) |> IO.iodata_to_binary()
      assert {:ok, ^expected} = :gen_tcp.recv(context.server, byte_size(expected), 500)
    end
  end

  describe "resetting" do
    setup [:setup_connection, :setup_inflight]

    test "cancel outgoing inflight packages", %{client_id: client_id} do
      publish = %Package.Publish{identifier: 1, topic: "foo", qos: 1}
      {:ok, ref} = Inflight.track(client_id, {:outgoing, publish})
      :ok = Inflight.reset(client_id)
      # the calling process should get a result response
      assert_receive {{Tortoise, ^client_id}, ^ref, {:error, :canceled}}
    end
  end

  describe "draining" do
    setup [:setup_connection, :setup_inflight]

    test "cancel outgoing inflight packages", %{client_id: client_id} = context do
      publish = %Package.Publish{identifier: 1, topic: "foo", qos: 1}
      {:ok, ref} = Inflight.track(client_id, {:outgoing, publish})
      # the publish should get dispatched
      expected = publish |> Package.encode() |> IO.iodata_to_binary()
      assert {:ok, ^expected} = :gen_tcp.recv(context.server, byte_size(expected), 500)
      # start draining
      :ok = Inflight.drain(client_id)
      # updates should have no effect at this point
      :ok = Inflight.update(client_id, {:received, %Package.Puback{identifier: 1}})
      # the calling process should get a result response
      assert_receive {{Tortoise, ^client_id}, ^ref, {:error, :canceled}}
      # Now the inflight manager should be in the draining state, new
      # outbound messages should not get accepted
      {:ok, ref} = Inflight.track(client_id, {:outgoing, publish})
      assert_receive {{Tortoise, ^client_id}, ^ref, {:error, :terminating}}
      # the remote should receive a disconnect package
      expected = %Package.Disconnect{} |> Package.encode() |> IO.iodata_to_binary()
      assert {:ok, ^expected} = :gen_tcp.recv(context.server, byte_size(expected), 500)
    end
  end
end
