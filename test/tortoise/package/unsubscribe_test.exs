defmodule Tortoise.Package.UnsubscribeTest do
  use ExUnit.Case
  use ExUnitProperties

  doctest Tortoise.Package.Unsubscribe

  alias Tortoise.Package

  property "encoding and decoding unsubscribe messages" do
    config = %Package.Unsubscribe{identifier: nil, topics: nil, properties: nil}

    check all unsubscribe <- Package.generate(config) do
      assert unsubscribe ==
               unsubscribe
               |> Package.encode()
               |> Package.decode()
    end
  end
end
