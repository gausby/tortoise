defmodule Tortoise.SessionTest do
  use ExUnit.Case, async: true
  doctest Tortoise.Session

  alias Tortoise.{Session, Package}

  test "track an incoming publish qos=1" do
    # The connection will receive the publish, store that in the
    # session, as the backend might be of a kind that doesn't throw
    # away packages. We will dispatch this publish message to the user
    # defined connection handler, and use the puback it produces to
    # progress the state of the session; then we will complete the
    # session.

    session = %Tortoise.Session{client_id: "foo"}

    publish_package =
      %Package.Publish{identifier: id} = %Package.Publish{qos: 1, identifier: 123, dup: false}

    # The track command will send back the publish message, this will
    # allow the backend to insert values to the user defined
    # properties (which doesn't make sense in the incoming scenario,
    # but will make sense in the outgoing cases)
    assert {{:cont, %Package.Publish{identifier: ^id} = publish_package}, %Session{}} =
             Session.track(session, {:incoming, publish_package})

    puback_package = %Package.Puback{identifier: id}

    assert {{:cont, %Package.Puback{identifier: ^id} = puback_package}, %Session{}} =
             Session.progress(session, {:outgoing, puback_package})

    assert {:ok, _} = Session.release(session, id)
  end

  test "track an outgoing publish qos=1" do
    session = %Tortoise.Session{client_id: "foo"}

    publish_package = %Package.Publish{qos: 1, identifier: nil, dup: false}

    assert {{:cont, %Package.Publish{identifier: id} = publish_package}, %Session{}} =
             Session.track(session, {:outgoing, publish_package})

    puback_package = %Package.Puback{identifier: id}

    assert {{:cont, %Package.Puback{identifier: ^id} = puback_package}, %Session{}} =
             Session.progress(session, {:incoming, puback_package})

    assert {:ok, _} = Session.release(session, id)
  end

  test "track an outgoing publish qos=2" do
    session = %Tortoise.Session{client_id: "foo"}

    publish_package = %Package.Publish{qos: 2, identifier: nil, dup: false}

    assert {{:cont, %Package.Publish{identifier: id} = publish_package}, %Session{}} =
             Session.track(session, {:outgoing, publish_package})

    pubrec_package = %Package.Pubrec{identifier: id}

    assert {{:cont, %Package.Pubrec{identifier: ^id} = pubrec_package}, %Session{}} =
             Session.progress(session, {:incoming, pubrec_package})

    pubrel_package = %Package.Pubrel{identifier: id}

    assert {{:cont, %Package.Pubrel{identifier: ^id} = pubrel_package}, %Session{}} =
             Session.progress(session, {:outgoing, pubrel_package})

    pubcomp_package = %Package.Pubcomp{identifier: id}

    assert {{:cont, %Package.Pubcomp{identifier: ^id} = pubcomp_package}, %Session{}} =
             Session.progress(session, {:incoming, pubcomp_package})

    assert {:ok, _} = Session.release(session, id)
  end

  test "track an incoming publish qos=2" do
    session = %Tortoise.Session{client_id: "foo"}

    publish_package = %Package.Publish{qos: 2, identifier: 125, dup: false}

    assert {{:cont, %Package.Publish{identifier: id} = publish_package}, %Session{}} =
             Session.track(session, {:incoming, publish_package})

    pubrec_package = %Package.Pubrec{identifier: id}

    assert {{:cont, %Package.Pubrec{identifier: ^id} = pubrec_package}, %Session{}} =
             Session.progress(session, {:outgoing, pubrec_package})

    pubrel_package = %Package.Pubrel{identifier: id}

    assert {{:cont, %Package.Pubrel{identifier: ^id} = pubrel_package}, %Session{}} =
             Session.progress(session, {:incoming, pubrel_package})

    pubcomp_package = %Package.Pubcomp{identifier: id}

    assert {{:cont, %Package.Pubcomp{identifier: ^id} = pubcomp_package}, %Session{}} =
             Session.progress(session, {:outgoing, pubcomp_package})

    assert {:ok, _} = Session.release(session, id)
  end

  test "track an outgoing subscribe package" do
    session = %Tortoise.Session{client_id: "foo"}

    subscribe_package = %Package.Subscribe{}

    assert {{:cont, %Package.Subscribe{identifier: id} = subscribe_package}, %Session{}} =
             Session.track(session, {:outgoing, subscribe_package})

    suback_package = %Package.Suback{identifier: id}

    assert {{:cont, %Package.Suback{identifier: id} = suback_package}, %Session{}} =
             Session.progress(session, {:incoming, suback_package})

    assert {:ok, _} = Session.release(session, id)
  end

  test "track an outgoing unsubscribe package" do
    session = %Tortoise.Session{client_id: "foo"}

    unsubscribe_package = %Package.Unsubscribe{}

    assert {{:cont, %Package.Unsubscribe{identifier: id} = unsubscribe_package}, %Session{}} =
             Session.track(session, {:outgoing, unsubscribe_package})

    unsuback_package = %Package.Unsuback{identifier: id}

    assert {{:cont, %Package.Unsuback{identifier: id} = suback_package}, %Session{}} =
             Session.progress(session, {:incoming, unsuback_package})

    assert {:ok, _} = Session.release(session, id)
  end
end
