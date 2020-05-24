defmodule Tortoise.Package.AuthTest do
  use ExUnit.Case
  use ExUnitProperties

  doctest Tortoise.Package.Auth

  alias Tortoise.Package

  property "encoding and decoding auth messages" do
    config = %Package.Auth{reason: nil, properties: nil}

    check all auth <- Package.generate(config) do
      assert auth ==
               auth
               |> Package.encode()
               |> Package.decode()
    end
  end
end
