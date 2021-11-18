defmodule Tortoise311.Package.Pingreq do
  @moduledoc false

  @opcode 12

  alias Tortoise311.Package

  @opaque t :: %__MODULE__{
            __META__: Package.Meta.t()
          }
  defstruct __META__: %Package.Meta{opcode: @opcode, flags: 0}

  @spec decode(<<_::16>>) :: t
  def decode(<<@opcode::4, 0::4, 0>>) do
    %__MODULE__{}
  end

  # Protocols ----------------------------------------------------------
  defimpl Tortoise311.Encodable do
    def encode(%Package.Pingreq{} = t) do
      [Package.Meta.encode(t.__META__), 0]
    end
  end
end
