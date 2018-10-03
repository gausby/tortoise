defmodule Tortoise.Package.PubackTest do
  use ExUnit.Case
  use EQC.ExUnit
  doctest Tortoise.Package.Puback

  alias Tortoise.Package

  import Tortoise.TestGenerators, only: [gen_puback: 0]

  property "encoding and decoding puback messages" do
    forall puback <- gen_puback() do
      ensure(
        puback ==
          puback
          |> Package.encode()
          |> Package.decode()
      )
    end
  end
end
