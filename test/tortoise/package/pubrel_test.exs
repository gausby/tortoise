defmodule Tortoise.Package.PubrelTest do
  use ExUnit.Case
  use EQC.ExUnit
  doctest Tortoise.Package.Pubrel

  alias Tortoise.Package

  import Tortoise.TestGenerators, only: [gen_pubrel: 0]

  property "encoding and decoding pubrel messages" do
    forall pubrel <- gen_pubrel() do
      ensure(
        pubrel ==
          pubrel
          |> Package.encode()
          |> Package.decode()
      )
    end
  end
end
