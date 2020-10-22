defprotocol Tortoise.Encodable do
  @moduledoc false

  @spec encode(t, Keyword.t()) :: iodata()
  def encode(package, opts)
end
