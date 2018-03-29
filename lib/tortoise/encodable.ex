defprotocol Tortoise.Encodable do
  @moduledoc false

  alias Tortoise.Package

  @opaque message ::
            Package.Connect.t()
            | Package.Connack.t()
            | Package.Publish.t()
            | Package.Puback.t()
            | Package.Pubrec.t()
            | Package.Pubrel.t()
            | Package.Pubcomp.t()
            | Package.Subscribe.t()
            | Package.Suback.t()
            | Package.Unsubscribe.t()
            | Package.Unsuback.t()
            | Package.Pingreq.t()
            | Package.Pingresp.t()
            | Package.Disconnect.t()

  @spec encode(message) :: iodata()
  def encode(package)
end
