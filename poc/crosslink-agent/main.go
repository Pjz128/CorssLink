package main

import (
	"embed"
	"log"
	"runtime"

	"github.com/wailsapp/wails/v3/pkg/application"
	"github.com/wailsapp/wails/v3/pkg/events"
	"github.com/wailsapp/wails/v3/pkg/icons"
)

//go:embed all:frontend/dist
var assets embed.FS

//go:embed build/appicon.png
var appIconBytes []byte

func main() {
	// Create the Wails application
	app := application.New(application.Options{
		Name:        "CrossLink Agent",
		Description: "Cross-device AI connectivity — access your home PC's Ollama models from your phone",
		Icon:        appIconBytes,
		Services: []application.Service{
			application.NewService(&AgentService{}),
		},
		Assets: application.AssetOptions{
			Handler: application.AssetFileServerFS(assets),
		},
		Windows: application.WindowsOptions{
			DisableQuitOnLastWindowClosed: true, // Keep running in tray when window is closed
		},
		Mac: application.MacOptions{
			ActivationPolicy: application.ActivationPolicyAccessory,
		},
	})

	// Create the main window (hidden by default — shown via tray)
	mainWindow := app.Window.NewWithOptions(application.WebviewWindowOptions{
		Title:  "CrossLink Agent",
		Name:   "main",
		Width:  400,
		Height: 500,
		Hidden: true, // Start hidden in tray
		URL:    "/",
	})

	// Intercept window close → hide to tray instead (RegisterHook runs BEFORE the default destroy listener)
	mainWindow.RegisterHook(events.Common.WindowClosing, func(event *application.WindowEvent) {
		event.Cancel() // Prevent default destroy
		mainWindow.Hide()
	})

	// Create system tray
	tray := app.SystemTray.New()

	// Set tray icon (use app icon, with fallback to built-in)
	if len(appIconBytes) > 0 {
		tray.SetIcon(appIconBytes)
	} else {
		tray.SetIcon(icons.SystrayLight)
	}

	tray.SetTooltip("CrossLink Agent")

	// Build tray menu
	menu := application.NewMenu()

	// Status item (non-clickable header)
	menu.Add("CrossLink Agent v0.1.0").SetEnabled(false)

	menu.AddSeparator()

	// Toggle main window
	menu.Add("Open Dashboard").OnClick(func(ctx *application.Context) {
		mainWindow.Show().Focus()
	})

	// Show QR code for pairing
	menu.Add("Show Pairing QR Code").OnClick(func(ctx *application.Context) {
		mainWindow.Show().Focus()
		app.Event.Emit("navigate", "qr-code")
	})

	menu.AddSeparator()

	// Settings
	menu.Add("Settings").OnClick(func(ctx *application.Context) {
		mainWindow.Show().Focus()
		app.Event.Emit("navigate", "settings")
	})

	menu.AddSeparator()

	// Quit
	menu.Add("Quit CrossLink Agent").OnClick(func(ctx *application.Context) {
		app.Quit()
	})

	tray.SetMenu(menu)

	// Attach window to tray (left-click = toggle window popup near tray)
	tray.AttachWindow(mainWindow).
		WindowOffset(8).
		WindowDebounce(200)

	log.Printf("CrossLink Agent starting on %s/%s", runtime.GOOS, runtime.GOARCH)
	log.Printf("System tray ready. Right-click for menu, left-click to toggle dashboard.")

	// Run the application — blocks until Quit()
	err := app.Run()
	if err != nil {
		log.Fatal(err)
	}
}
