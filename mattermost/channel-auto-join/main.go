// Command channel-auto-join is a Mattermost server plugin that adds every active, non-bot
// member of a team to each public channel created in that team.
package main

import (
	"github.com/mattermost/mattermost/server/public/model"
	"github.com/mattermost/mattermost/server/public/plugin"
)

const perPage = 200

type Plugin struct {
	plugin.MattermostPlugin
}

// ChannelHasBeenCreated runs after the channel is stored, outside the request that created it.
func (p *Plugin) ChannelHasBeenCreated(_ *plugin.Context, channel *model.Channel) {
	if channel.Type != model.ChannelTypeOpen {
		return
	}
	added, failed := 0, 0
	// Channel membership does not affect the listing, so adding members does not shift the pages.
	for page := 0; ; page++ {
		// Not GetUsers: the plugin API ignores its InTeamId and lists every user on the server.
		users, appErr := p.API.GetUsersInTeam(channel.TeamId, page, perPage)
		if appErr != nil {
			p.API.LogError("Listing team members failed", "channel_id", channel.Id, "team_id", channel.TeamId, "error", appErr.Error())
			return
		}
		for _, user := range users {
			if user.DeleteAt != 0 || user.IsBot || user.Id == channel.CreatorId {
				continue
			}
			// Same as joining a default channel: a "joined the channel" post, no notification.
			if _, appErr := p.API.AddChannelMember(channel.Id, user.Id); appErr != nil {
				p.API.LogWarn("Adding user to channel failed", "channel_id", channel.Id, "user_id", user.Id, "error", appErr.Error())
				failed++
				continue
			}
			added++
		}
		if len(users) < perPage {
			break
		}
	}
	p.API.LogInfo("Added team members to new public channel", "channel_id", channel.Id, "added", added, "failed", failed)
}

func main() {
	plugin.ClientMain(&Plugin{})
}
