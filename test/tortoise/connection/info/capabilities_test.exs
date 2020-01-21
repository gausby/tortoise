defmodule Tortoise.Connection.Info.CapabilitiesTest do
  use ExUnit.Case, async: true
  doctest Tortoise.Connection.Info.Capabilities

  alias Tortoise.Package.Subscribe
  alias Tortoise.Connection.Info

  defp create_config(properties) do
    # server_keep_alive needs to be set
    struct!(%Info.Capabilities{}, properties)
  end

  describe "shared_subscription_available: false" do
    test "return error if shared subscription is placed" do
      no_shared_subscription = create_config(shared_subscription_available: false)

      shared_topic_filter = "$share/foo/bar"
      subscribe = %Subscribe{topics: [{shared_topic_filter, qos: 0}]}

      assert {:invalid, reasons} = Info.Capabilities.validate(no_shared_subscription, subscribe)
      assert {:shared_subscription_not_available, shared_topic_filter} in reasons
    end
  end

  describe "wildcard_subscription_available: false" do
    test "return error if a subscription with a wildcard is placed" do
      no_shared_subscription = create_config(wildcard_subscription_available: false)

      topic_filter_with_single_level_wildcard = "foo/+/bar"
      topic_filter_with_multi_level_wildcard = "foo/#"

      subscribe = %Subscribe{
        topics: [
          {topic_filter_with_single_level_wildcard, qos: 0},
          {topic_filter_with_multi_level_wildcard, qos: 0}
        ]
      }

      assert {:invalid, reasons} = Info.Capabilities.validate(no_shared_subscription, subscribe)

      assert {:wildcard_subscription_not_available, topic_filter_with_single_level_wildcard} in reasons

      assert {:wildcard_subscription_not_available, topic_filter_with_multi_level_wildcard} in reasons
    end
  end

  describe "subscription_identifier_available: false" do
    test "return error if shared subscription is placed" do
      config = create_config(subscription_identifiers_available: false)

      subscribe = %Subscribe{
        topics: [{"foo/bar", qos: 0}],
        properties: [subscription_identifier: 5]
      }

      assert {:invalid, reasons} = Info.Capabilities.validate(config, subscribe)
      assert :subscription_identifier_not_available in reasons
    end
  end
end
