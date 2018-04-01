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
    assert %Track{pending: [{:dispatch, %Package.Puback{}} | _]} = state

    state = Track.update(state, {:dispatched, %Package.Puback{identifier: id}})
    assert %Track{identifier: ^id, pending: []} = state
  end

  test "progress a qos 2 receive" do
    id = 0x0001
    publish = %Package.Publish{qos: 2, identifier: id}

    state = Track.create(:positive, publish)
    assert %Track{pending: [{:dispatch, %Package.Pubrec{}} | _]} = state

    state = Track.update(state, {:dispatched, %Package.Pubrec{identifier: id}})
    assert %Track{pending: [{:expect, %Package.Pubrel{}} | _]} = state

    state = Track.update(state, {:received, %Package.Pubrel{identifier: id}})
    assert %Track{pending: [{:dispatch, %Package.Pubcomp{}} | _]} = state

    state = Track.update(state, {:dispatched, %Package.Pubcomp{identifier: id}})
    assert %Track{identifier: ^id, pending: []} = state
  end

  test "progress a qos 1 publish" do
    id = 0x0001
    publish = %Package.Publish{qos: 1, identifier: id}
    caller = {self(), make_ref()}

    state = Track.create({:negative, caller}, publish)
    assert %Track{pending: [{:dispatch, publish} | _]} = state

    state = Track.update(state, {:dispatched, publish})
    assert %Track{pending: [{:expect, %Package.Puback{}} | _]} = state

    state = Track.update(state, {:received, %Package.Puback{identifier: id}})
    assert %Track{identifier: ^id, pending: [], caller: ^caller} = state
  end

  test "progress a qos 2 publish" do
    id = 0x0001
    publish = %Package.Publish{qos: 2, identifier: id}
    caller = {self(), make_ref()}

    state = Track.create({:negative, caller}, publish)
    assert %Track{pending: [{:dispatch, publish} | _]} = state

    state = Track.update(state, {:dispatched, publish})
    assert %Track{pending: [{:expect, %Package.Pubrec{}} | _]} = state

    state = Track.update(state, {:received, %Package.Pubrec{identifier: id}})
    assert %Track{pending: [{:dispatch, %Package.Pubrel{}} | _]} = state

    state = Track.update(state, {:dispatched, %Package.Pubrel{identifier: id}})
    assert %Track{pending: [{:expect, %Package.Pubcomp{}}]} = state

    state = Track.update(state, {:received, %Package.Pubcomp{identifier: id}})
    assert %Track{identifier: ^id, pending: [], caller: ^caller} = state
  end

  describe "rollback/1" do
    # todo, this could be described as a property
    test "roll back to dispatch state" do
      publish = %Package.Publish{qos: 2, identifier: 1}
      initial_state = Track.create(:positive, publish)
      command = {:dispatched, %Package.Pubrec{identifier: 1}}
      state = Track.update(initial_state, command)

      assert ^initial_state = Track.rollback(state)
    end

    test "roll back to expect state" do
      publish = %Package.Publish{qos: 2, identifier: 1}
      caller = {self(), make_ref()}
      state = Track.create({:negative, caller}, publish)
      command = {:dispatched, publish}
      target_state = state = Track.update(state, command)
      command = {:received, %Package.Pubrec{identifier: 1}}
      state = Track.update(state, command)

      assert ^target_state = Track.rollback(state)
    end

    test "rolling back to a publish dispatch should set the duplication flag" do
      # setup tracking of an outgoing publish qos 2
      publish = %Package.Publish{qos: 2, identifier: 1, dup: false}
      caller = {self(), make_ref()}
      # record data in initial state for later assertions
      initial_state = Track.create({:negative, caller}, publish)
      %{pending: [{:dispatch, ^publish} | pending]} = initial_state
      # progress the state
      command = {:dispatched, publish}
      state = Track.update(initial_state, command)
      # When we roll back the "dup" flag should get set on the publish
      dupped_publish = %Package.Publish{publish | dup: true}

      assert Track.rollback(state) == %Track{
               initial_state
               | pending: [{:dispatch, dupped_publish} | pending]
             }
    end
  end
end
