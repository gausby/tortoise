defmodule Tortoise.Package.Pingreq do
  @moduledoc false

  @opcode 12

  alias Tortoise.Package

  @opaque t :: %__MODULE__{
            __META__: Package.Meta.t()
          }
  defstruct __META__: %Package.Meta{opcode: @opcode, flags: 0}

  @spec decode(<<_::16>>, opts :: Keyword.t()) :: t
  def decode(<<@opcode::4, 0::4, 0>>, _opts) do
    %__MODULE__{}
  end

  # Protocols ----------------------------------------------------------
  defimpl Tortoise.Encodable do
    # Note: The Pingreq package is the same for both version 3.1.1 and
    # version 5, no options apply
    def encode(%Package.Pingreq{} = t, _opts) do
      [Package.Meta.encode(t.__META__), 0]
    end
  end

  if Code.ensure_loaded?(StreamData) do
    defimpl Tortoise.Generatable do
      import StreamData

      def generate(%type{__META__: _meta} = package) do
        values = package |> Map.from_struct()

        fixed_list(Enum.map(values, &constant(&1)))
        |> bind(fn data ->
          fixed_map([
            {:__struct__, type}
            | for({k, v} <- data, do: {k, constant(v)})
          ])
        end)
      end
    end
  end
end
