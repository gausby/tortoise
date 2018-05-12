defmodule Tortoise.Package.Meta do
  @opaque t() :: %__MODULE__{
            opcode: 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14,
            flags: non_neg_integer()
          }
  @enforce_keys [:opcode]
  defstruct opcode: 0, flags: 0

  def encode(meta) do
    <<meta.opcode::4, meta.flags::4>>
  end
end
