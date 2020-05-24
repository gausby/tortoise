defmodule Tortoise.Package.PublishTest do
  use ExUnit.Case
  use ExUnitProperties

  doctest Tortoise.Package.Publish

  alias Tortoise.Package

  property "encoding and decoding publish messages" do
    config = %Package.Publish{
      identifier: nil,
      topic: nil,
      payload: nil,
      qos: nil,
      dup: nil,
      retain: nil,
      properties: nil
    }

    check all publish <- Package.generate(config) do
      assert publish ==
               publish
               |> Package.encode()
               |> Package.decode()
    end
  end
end
