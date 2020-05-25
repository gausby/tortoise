defmodule Tortoise.Package.ConnectTest do
  use ExUnit.Case
  use ExUnitProperties

  doctest Tortoise.Package.Connect

  alias Tortoise.Package

  property "encoding and decoding connect messages" do
    config = %Package.Connect{
      user_name: nil,
      password: nil,
      clean_start: nil,
      keep_alive: nil,
      client_id: nil,
      will: nil,
      properties: nil
    }

    check all connect <- Package.generate(config) do
      assert connect ==
               connect
               |> Package.encode()
               |> Package.decode()
    end
  end
end
