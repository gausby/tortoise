defmodule Tortoise.Package.Meta do
  @moduledoc false

  alias Tortoise.Package

  @opaque t() :: %__MODULE__{
            opcode: 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14,
            flags: non_neg_integer()
          }
  @enforce_keys [:opcode]
  defstruct opcode: 0, flags: 0

  def encode(meta) do
    <<meta.opcode::4, meta.flags::4>>
  end

  @doc """
  Infer the meta values from the package content and type
  """
  def infer(%Package.Publish{dup: dup, qos: qos, retain: retain} = data) do
    <<flags::4>> = <<flag(dup)::1, qos::integer-size(2), flag(retain)::1>>
    infered_meta = %__MODULE__{opcode: 3, flags: flags}
    %Package.Publish{data | __META__: infered_meta}
  end

  def infer(%_type{__META__: _} = data) do
    data
  end

  defp flag(true), do: 1
  defp flag(false), do: 0
end
