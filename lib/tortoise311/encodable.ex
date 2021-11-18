defprotocol Tortoise311.Encodable do
  @moduledoc false

  @spec encode(t) :: iodata()
  def encode(package)
end
