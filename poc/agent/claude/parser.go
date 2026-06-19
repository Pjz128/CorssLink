package claude

import (
	"bufio"
	"encoding/json"
	"io"
	"log"
)

// ParseEvent is the parsed result of one Claude stdout JSON line.
type ParseEvent struct {
	Type string // "init", "thinking", "text", "tool_use", "tool_input",
	// "tool_result", "done", "result", "error", "status"

	// Text/thinking streaming
	Token string

	// Tool call
	ToolID    string
	ToolName  string
	ToolInput json.RawMessage

	// Tool result (from a following message)
	ToolResultOutput  string
	ToolResultIsError bool

	// Session metadata
	SessionID string
	Model     string

	// Completion
	StopReason string
	IsError    bool

	// Usage (extracted from message_delta / message_stop)
	InputTokens  int
	OutputTokens int

	// Raw data for forwarding
	Raw json.RawMessage
}

// startParser launches a goroutine that reads JSON lines from r,
// converts them into ParseEvents, and sends them to out.
// It closes out when the reader is exhausted.
func startParser(r io.Reader, out chan<- ParseEvent) {
	go func() {
		defer close(out)
		scanner := bufio.NewScanner(r)
		// Claude stream-json can emit long lines (tool results, etc.)
		scanner.Buffer(make([]byte, 64*1024), 10*1024*1024)

		var currentToolID string
		var currentToolName string

		for scanner.Scan() {
			line := scanner.Bytes()
			if len(line) == 0 {
				continue
			}

			var msg claudeMsg
			if err := json.Unmarshal(line, &msg); err != nil {
				log.Printf("[claude-parser] skip malformed line: %v", err)
				continue
			}

			switch msg.Type {
			case "system":
				if msg.Subtype == "init" {
					// session_id and model are at the top level of system/init
					out <- ParseEvent{
						Type:      "init",
						SessionID: msg.SessionID,
						Model:     msg.Model,
					}
				} else {
					out <- ParseEvent{Type: "status", SessionID: msg.SessionID}
				}
			case "stream_event":
				var evt streamEvent
				if err := json.Unmarshal(msg.Event, &evt); err != nil {
					continue
				}
				ev := parseStreamEvent(&evt, msg.SessionID, &currentToolID, &currentToolName)
				out <- ev
			case "result":
				out <- ParseEvent{
					Type:      "result",
					IsError:   msg.IsError,
					SessionID: msg.SessionID,
				}
			default:
				// ignore unhandled top-level types
			}
		}
	}()
}

func parseStreamEvent(evt *streamEvent, sessionID string, currentToolID *string, currentToolName *string) ParseEvent {
	switch evt.Type {
	case "content_block_start":
		if evt.ContentBlock == nil {
			return ParseEvent{Type: "status", SessionID: sessionID}
		}
		switch evt.ContentBlock.Type {
		case "thinking":
			return ParseEvent{Type: "thinking_start", SessionID: sessionID}
		case "text":
			return ParseEvent{Type: "text_start", SessionID: sessionID}
		case "tool_use":
			*currentToolID = evt.ContentBlock.ID
			*currentToolName = evt.ContentBlock.Name
			return ParseEvent{
				Type:      "tool_use",
				ToolID:    evt.ContentBlock.ID,
				ToolName:  evt.ContentBlock.Name,
				SessionID: sessionID,
			}
		}
	case "content_block_delta":
		switch evt.Delta.Type {
		case "thinking_delta":
			return ParseEvent{
				Type:      "thinking",
				Token:     evt.Delta.Thinking,
				SessionID: sessionID,
			}
		case "text_delta":
			return ParseEvent{
				Type:      "text",
				Token:     evt.Delta.Text,
				SessionID: sessionID,
			}
		case "input_json_delta":
			return ParseEvent{
				Type:      "tool_input",
				Token:     evt.Delta.PartialJSON,
				ToolID:    *currentToolID,
				ToolName:  *currentToolName,
				SessionID: sessionID,
			}
		case "signature_delta":
			return ParseEvent{Type: "status", SessionID: sessionID} // ignore
		}
	case "content_block_stop":
		return ParseEvent{
			Type:      "tool_stop",
			ToolID:    *currentToolID,
			ToolName:  *currentToolName,
			SessionID: sessionID,
		}
	case "message_delta":
		pe := ParseEvent{
			Type:       "done",
			StopReason: evt.Delta.StopReason,
			SessionID:  sessionID,
		}
		if evt.Usage != nil {
			pe.InputTokens = evt.Usage.InputTokens
			pe.OutputTokens = evt.Usage.OutputTokens
		}
		return pe
	case "message_stop":
		pe := ParseEvent{
			Type:      "done",
			SessionID: sessionID,
		}
		if evt.Usage != nil {
			pe.InputTokens = evt.Usage.InputTokens
			pe.OutputTokens = evt.Usage.OutputTokens
		}
		return pe
	}
	return ParseEvent{Type: "status", SessionID: sessionID}
}
