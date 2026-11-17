FreeRADIUS 4 changes the configuration format; nothing moves to it automatically (this image stays on 3.2).

Before moving, check each place that runs FreeRADIUS:

- [ ] this site image (the generated `proxy.conf` becomes `radius` modules; the entrypoint generates it)
- [ ] the central RADIUS servers (pinned to 3.2.x)
- [ ] any other FreeRADIUS 3 deployment that shares this configuration style, such as firewall plugins
- [ ] read the upstream upgrade guide: `doc/antora/modules/howto/pages/upgrade/index.adoc`
