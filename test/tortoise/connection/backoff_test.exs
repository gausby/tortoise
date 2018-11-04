defmodule Tortoise.Connection.BackoffTest do
  use ExUnit.Case, async: true
  doctest Tortoise.Connection.Backoff

  alias Tortoise.Connection.Backoff

  test "should not exceed maximum interval time" do
    min = 100
    max = 300
    backoff = Backoff.new(min_interval: 100, max_interval: 300)
    assert {0, backoff} = Backoff.next(backoff)
    assert {^min, backoff} = Backoff.next(backoff)
    {_, backoff} = Backoff.next(backoff)
    assert {^max, backoff} = Backoff.next(backoff)
    # should start over now
    assert {0, backoff} = Backoff.next(backoff)
    assert {^min, _} = Backoff.next(backoff)
  end

  test "reset" do
    backoff = Backoff.new(min_interval: 10)
    assert {0, backoff} = Backoff.next(backoff)
    assert {_, backoff = snapshot} = Backoff.next(backoff)
    assert {_, backoff} = Backoff.next(backoff)
    assert %Backoff{} = backoff = Backoff.reset(backoff)
    assert {0, backoff} = Backoff.next(backoff)
    assert {_, ^snapshot} = Backoff.next(backoff)
  end
end
