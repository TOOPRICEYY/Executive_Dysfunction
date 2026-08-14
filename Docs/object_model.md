# Object Model

## Activity Group

A reusable, live collection of apps, websites, categories, and other targets. Target identifiers should be portable across platforms wherever possible.

- A Blocking Group may independently link one or more Activity Groups.
- Changes propagate to every baseline and retreat linking the Activity Group.
- Deletion is a protected modification and removes its links from live configurations.
- Retreat history retains a deleted marker; recreation omits deleted Activity Groups.

## Time Window

The schedule owned by a Blocking Group.

- Contains daily or weekly active slots and whether painted time represents blocking or allowance.
- Is not reusable or shared; copying creates an independent value.
- A Time Window Template is only a copy source. Inserting one creates no live reference.

## Usage Budget

An optional value owned by a Blocking Group, separate from its Time Window.

- May specify daily and/or weekly limits.
- A missing limit means that period is unlimited.

## Blocking Group

An independently evaluated restriction containing:

- One or more Activity Group links.
- One owned Time Window.
- One optional Usage Budget.
- Enabled state, enforcement configuration, and modification security policy.

Blocking Groups are created and edited within the Baseline or a Retreat. Activity Groups linked by different Blocking Groups are not merged.

## Baseline

The live default configuration.

- Contains an arbitrary collection of Blocking Groups.
- Has its own modification security policy.
- Disabled or unused Blocking Groups remain visible but inactive until deleted.

## Retreat

A versioned, temporary configuration containing an arbitrary collection of Blocking Groups.

- Properties: name, goal, planned start and end, Blocking Groups, and modification security policy.
- State: `draft`, `scheduled`, `active`, `completed`, or `endedEarly`.
- Only Retreats are versioned.
- A version preserves its Blocking Groups, Time Windows, Usage Budgets, and Activity Group links.
- Activity Group content remains live. Recreation resolves links to current content.
- Completed Retreats record actual start, end, terminal state, and version used.
- Protected active-Retreat changes create a new version.

## Modification Security

Editing, unlinking, or deleting is a modification. Its effective policy is the field-wise restrictive maximum of every applicable policy on the object, its Blocking Group, and its Baseline or Retreat. App defaults are resolved before combining policies.

- Security enabled: enabled if any policy enables it.
- Passage word count and unlock delay: maximum.
- Repeated confirmations: required if any policy requires them.
- Confirmation and editing windows: minimum.
- Temporary extensions: allowed only if every policy allows them.
- Maximum extension duration: minimum.

Authorization uses a snapshot of the effective policy. Tightening an applicable policy invalidates an incomplete authorization; later weakening does not shorten one already in progress.
