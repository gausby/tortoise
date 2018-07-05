defmodule Tortoise.Connection.BackoffTest do
  use ExUnit.Case, async: true
  doctest Tortoise.Connection.Backoff

  alias Tortoise.Connection.Backoff

  test "should not exceed maximum interval time" do
    min = 100
    max = 300
    backoff = Backoff.new(min_interval: 100, max_interval: 300)
    assert %{value: ^min} = backoff = Backoff.next(backoff)
    backoff = Backoff.next(backoff)
    assert %{value: ^max} = backoff = Backoff.next(backoff)
    # should roll back to min interval now
    assert %{value: ^min} = Backoff.next(backoff)
  end

  test "should not exceed timeout value" do
    backoff = Backoff.new(timeout: 300, min_interval: 100)
    assert backoff = Backoff.next(backoff)
    assert backoff = Backoff.next(backoff)
    assert {:error, :timeout} = Backoff.next(backoff)
  end

  test "reset" do
    backoff = Backoff.new(min_interval: 10)
    assert backoff = snapshot = Backoff.next(backoff)
    assert backoff = Backoff.next(backoff)
    assert %Backoff{} = backoff = Backoff.reset(backoff)
    assert ^snapshot = Backoff.next(backoff)
  end

  test "get current timeout value" do
    backoff = Backoff.new(min_interval: 10)
    assert %Backoff{value: timeout} = backoff = Backoff.next(backoff)
    assert ^timeout = Backoff.timeout(backoff)
  end
end
