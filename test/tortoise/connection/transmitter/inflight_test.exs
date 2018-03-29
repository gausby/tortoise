defmodule Tortoise.Connection.Transmitter.InflightTest do
  @moduledoc false
  use ExUnit.Case
  doctest Tortoise.Connection.Transmitter.Inflight

  alias Tortoise.Connection.Transmitter.Inflight
  alias Tortoise.Package

  test "progress a qos 1 receive" do
    %{identifier: id} = publish = %Package.Publish{qos: 1, identifier: 0x0001}

    state = Inflight.track(:positive, publish)
    assert %Inflight{pending: [{:dispatch, %Package.Puback{}} | _]} = state

    state = Inflight.update(state, {:dispatched, %Package.Puback{identifier: id}})
    assert %Inflight{identifier: ^id, pending: []} = state
  end

  test "progress a qos 2 receive" do
    %{identifier: id} = publish = %Package.Publish{qos: 2, identifier: 0x0001}

    state = Inflight.track(:positive, publish)
    assert %Inflight{pending: [{:dispatch, %Package.Pubrec{}} | _]} = state

    state = Inflight.update(state, {:dispatched, %Package.Pubrec{identifier: id}})
    assert %Inflight{pending: [{:expect, %Package.Pubrel{}} | _]} = state

    state = Inflight.update(state, {:received, %Package.Pubrel{identifier: id}})
    assert %Inflight{pending: [{:dispatch, %Package.Pubcomp{}} | _]} = state

    state = Inflight.update(state, {:dispatched, %Package.Pubcomp{identifier: id}})
    assert %Inflight{identifier: ^id, pending: []} = state
  end

  test "progress a qos 1 publish" do
    %{identifier: id} = publish = %Package.Publish{qos: 1, identifier: 0x0001}
    caller = {self(), make_ref()}

    state = Inflight.track({:negative, caller}, publish)
    assert %Inflight{pending: [{:dispatch, publish} | _]} = state

    state = Inflight.update(state, {:dispatched, publish})
    assert %Inflight{pending: [{:expect, %Package.Puback{}} | _]} = state

    state = Inflight.update(state, {:received, %Package.Puback{identifier: id}})
    assert %Inflight{identifier: ^id, pending: [], caller: ^caller} = state
  end

  test "progress a qos 2 publish" do
    %{identifier: id} = publish = %Package.Publish{qos: 2, identifier: 0x0001}
    caller = {self(), make_ref()}

    state = Inflight.track({:negative, caller}, publish)
    assert %Inflight{pending: [{:dispatch, publish} | _]} = state

    state = Inflight.update(state, {:dispatched, publish})
    assert %Inflight{pending: [{:expect, %Package.Pubrec{}} | _]} = state

    state = Inflight.update(state, {:received, %Package.Pubrec{identifier: id}})
    assert %Inflight{pending: [{:dispatch, %Package.Pubrel{}} | _]} = state

    state = Inflight.update(state, {:dispatched, %Package.Pubrel{identifier: id}})
    assert %Inflight{pending: [{:expect, %Package.Pubcomp{}}]} = state

    state = Inflight.update(state, {:received, %Package.Pubcomp{identifier: id}})
    assert %Inflight{identifier: ^id, pending: [], caller: ^caller} = state
  end
end
