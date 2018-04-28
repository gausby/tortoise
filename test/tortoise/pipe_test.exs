defmodule Tortoise.PipeTest do
  use ExUnit.Case
  doctest Tortoise.Pipe

  alias Tortoise.Pipe

  test "generate a pipe", context do
    assert %Pipe{client_id: context.test, socket: "hello"}
  end
end
