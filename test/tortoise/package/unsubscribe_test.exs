defmodule Tortoise.Package.UnsubscribeTest do
  use ExUnit.Case
  use EQC.ExUnit
  doctest Tortoise.Package.Unsubscribe

  import Tortoise.TestGenerators, only: [gen_unsubscribe: 0]

  alias Tortoise.Package

  property "encoding and decoding unsubscribe messages" do
    forall unsubscribe <- gen_unsubscribe() do
      ensure(
        unsubscribe ==
          unsubscribe
          |> Package.encode()
          |> Package.decode()
      )
    end
  end
end
