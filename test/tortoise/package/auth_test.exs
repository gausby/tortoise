defmodule Tortoise.Package.AuthTest do
  use ExUnit.Case
  use EQC.ExUnit
  doctest Tortoise.Package.Auth

  alias Tortoise.Package

  import Tortoise.TestGenerators, only: [gen_auth: 0]

  property "encoding and decoding auth messages" do
    forall auth <- gen_auth() do
      ensure(
        auth ==
          auth
          |> Package.encode()
          |> Package.decode()
      )
    end
  end
end
