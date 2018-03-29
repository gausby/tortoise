defmodule Tortoise.Package.SubscribeTest do
  use ExUnit.Case
  use EQC.ExUnit
  doctest Tortoise.Package.Subscribe

  import Tortoise.TestGenerators, only: [gen_subscribe: 0]

  alias Tortoise.Package

  property "encoding and decoding subscribe messages" do
    forall subscribe <- gen_subscribe() do
      ensure(
        subscribe ==
          subscribe
          |> Package.encode()
          |> Package.decode()
      )
    end
  end
end
