defmodule Tortoise.Package.PublishTest do
  use ExUnit.Case
  # use EQC.ExUnit
  doctest Tortoise.Package.Publish

  # import Tortoise.TestGenerators, only: [gen_publish: 0]

  # alias Tortoise.Package

  # property "encoding and decoding publish messages" do
  #   forall publish <- gen_publish() do
  #     ensure(
  #       publish ==
  #         publish
  #         |> Package.encode()
  #         |> Package.decode()
  #     )
  #   end
  # end
  @tag :skip
  test "encoding and decoding publish messages"
end
