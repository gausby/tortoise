defprotocol Tortoise.Encodable do
  @moduledoc false

  alias Tortoise.Package

  @spec encode(t) :: iodata()
  def encode(package)
end
