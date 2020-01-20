defmodule Tortoise.Connection.ConfigTest do
  use ExUnit.Case, async: true
  doctest Tortoise.Connection.Config

  alias Tortoise.Package.Subscribe
  alias Tortoise.Connection.Config

  defp create_config(properties) do
    # server_keep_alive needs to be set
    struct!(%Config{server_keep_alive: 60}, properties)
  end

  describe "shared_subscription_available: false" do
    test "return error if shared subscription is placed" do
      no_shared_subscription = create_config(shared_subscription_available: false)

      shared_topic_filter = "$share/foo/bar"
      subscribe = %Subscribe{topics: [{shared_topic_filter, qos: 0}]}

      assert {:invalid, reasons} = Config.validate(no_shared_subscription, subscribe)
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

      assert {:invalid, reasons} = Config.validate(no_shared_subscription, subscribe)

      assert {:wildcard_subscription_not_available, topic_filter_with_single_level_wildcard} in reasons

      assert {:wildcard_subscription_not_available, topic_filter_with_multi_level_wildcard} in reasons
    end
  end
end
