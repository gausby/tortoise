defprotocol Tortoise.Encodable do
  @moduledoc false

  @spec encode(t) :: iodata()
  def encode(package)
end
