defmodule TestDriver do
  @behaviour Tortoise.Driver

  def init(state) do
    {:ok, state}
  end

  def on_publish(_topic, _hello, state) do
    {:ok, state}
  end

  def disconnect(_state) do
    :ok
  end
end

defmodule Tortoise.ConnectionTest do
  use ExUnit.Case
  doctest Tortoise.Connection
end
