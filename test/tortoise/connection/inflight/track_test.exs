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
end
