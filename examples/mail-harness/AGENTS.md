# Optional tailmail integration

When an answer, clarification, or approval is needed to continue, email the
configured user and wait for their reply instead of guessing. Check and process
queued mail before finishing work. Use the `tailmail-mail` skill in
`.agents/skills/tailmail-mail/SKILL.md` for the workflow.

The skill uses the local `tailmail` account. Keep its credentials in the
machine-local configuration; project files and prompts contain no passwords.
