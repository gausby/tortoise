defmodule TortoiseTest do
  use ExUnit.Case
  doctest Tortoise

  test "greets the world" do
    assert {:error, {:already_started, _pid}} = Tortoise.start(:normal, [])
  end
end
