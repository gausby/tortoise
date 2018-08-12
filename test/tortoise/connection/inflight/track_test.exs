defmodule Tortoise.Connection.Inflight.TrackTest do
  @moduledoc false
  use ExUnit.Case
  doctest Tortoise.Connection.Inflight.Track

  alias Tortoise.Connection.Inflight.Track
  alias Tortoise.Package

  test "progress a qos 1 receive" do
    id = 0x0001
    publish = %Package.Publish{qos: 1, identifier: id}

    state = Track.create(:positive, publish)

    assert %Track{
             pending: [
               [
                 {:dispatch, %Package.Puback{identifier: ^id}},
                 :cleanup
               ]
             ]
           } = state

    assert {next_action, resolution} = Track.next(state)
    assert {:dispatch, %Package.Puback{identifier: ^id}} = next_action
    assert :cleanup = resolution

    assert %Track{identifier: ^id, pending: []} = Track.resolve(state, resolution)
  end

  test "progress a qos 2 receive" do
    id = 0x0001
    publish = %Package.Publish{qos: 2, identifier: id}

    state = Track.create(:positive, publish)
    assert %Track{pending: [[{:dispatch, %Package.Pubrec{}} | _] | _]} = state

    {next_action, resolution} = Track.next(state)
    assert {:dispatch, %Package.Pubrec{identifier: ^id}} = next_action

    state = Track.resolve(state, resolution)
    {next_action, resolution} = Track.next(state)
    assert {:dispatch, %Package.Pubcomp{identifier: ^id}} = next_action
    assert :cleanup = resolution

    assert %Track{identifier: ^id, pending: []} = Track.resolve(state, resolution)
  end

  test "progress a qos 1 publish" do
    id = 0x0001
    publish = %Package.Publish{qos: 1, identifier: id}
    caller = {self(), make_ref()}

    state = Track.create({:negative, caller}, publish)
    assert %Track{pending: [[{:dispatch, ^publish}, _] | _]} = state

    {next_action, resolution} = Track.next(state)
    assert {:dispatch, %Package.Publish{identifier: ^id}} = next_action
    assert {:received, %Package.Puback{identifier: ^id}} = resolution
    state = Track.resolve(state, resolution)

    {next_action, resolution} = Track.next(state)
    assert {:respond, ^caller} = next_action
    assert :cleanup = resolution
    state = Track.resolve(state, resolution)

    assert %Track{identifier: ^id, pending: []} = state
  end

  test "progress a qos 2 publish" do
    id = 0x0001
    publish = %Package.Publish{qos: 2, identifier: id}
    caller = {self(), make_ref()}

    state = Track.create({:negative, caller}, publish)
    assert %Track{pending: [[{:dispatch, publish}, _] | _]} = state

    {next_action, resolution} = Track.next(state)
    assert {:dispatch, %Package.Publish{identifier: ^id}} = next_action
    assert {:received, %Package.Pubrec{identifier: ^id}} = resolution
    state = Track.resolve(state, resolution)

    {next_action, resolution} = Track.next(state)
    assert {:dispatch, %Package.Pubrel{identifier: ^id}} = next_action
    assert {:received, %Package.Pubcomp{identifier: ^id}} = resolution
    state = Track.resolve(state, resolution)

    {next_action, resolution} = Track.next(state)
    assert {:respond, ^caller} = next_action
    assert :cleanup = resolution
    state = Track.resolve(state, resolution)

    assert %Track{identifier: ^id, pending: []} = state
  end

  test "progress a subscribe" do
    id = 0x0001
    subscribe = %Package.Subscribe{identifier: id, topics: [{"foo/bar", 0}]}
    suback = %Package.Suback{identifier: id, acks: [ok: 0]}
    caller = {self(), make_ref()}

    state = Track.create({:negative, caller}, subscribe)
    assert %Track{pending: [[{:dispatch, ^subscribe}, _] | _]} = state

    {next_action, resolution} = Track.next(state)
    assert {:dispatch, ^subscribe} = next_action
    assert {:received, %Package.Suback{identifier: ^id}} = resolution
    state = Track.resolve(state, {:received, suback})

    {next_action, resolution} = Track.next(state)
    assert {:respond, ^caller} = next_action
    assert :cleanup = resolution
    state = Track.resolve(state, resolution)

    assert %Track{identifier: ^id, pending: []} = state
  end

  test "progress an unsubscribe" do
    id = 0x0001
    unsubscribe = %Package.Unsubscribe{identifier: id, topics: ["foo/bar"]}
    unsuback = %Package.Unsuback{identifier: id}
    caller = {self(), make_ref()}

    state = Track.create({:negative, caller}, unsubscribe)
    assert %Track{pending: [[{:dispatch, ^unsubscribe}, _] | _]} = state

    {next_action, resolution} = Track.next(state)
    assert {:dispatch, ^unsubscribe} = next_action
    assert {:received, %Package.Unsuback{identifier: ^id}} = resolution
    state = Track.resolve(state, {:received, unsuback})

    {next_action, resolution} = Track.next(state)
    assert {:respond, ^caller} = next_action
    assert :cleanup = resolution
    state = Track.resolve(state, resolution)

    assert %Track{identifier: ^id, pending: []} = state
  end
end
