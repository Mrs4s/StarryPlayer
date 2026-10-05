// What the plugin learns as it goes and needs later: the signed-in profile, which playlists are
// the account's own (v6 detail) and which is its liked list, and the recommendation token (`alg`)
// personal FM gave each song (liking, skipping and the play report send it back).

import type { Profile } from '../../sdk/starry';

let profile: Profile | undefined;

export const signedInProfile = () => profile;
export const currentUserID = () => profile?.userID;

export function setSignedInProfile(next: Profile | undefined): void {
  profile = next;
}

/** Learnt from one account's playlist list; `owner` says whose, so an account signed in since does not read it. */
let library: { owner: string; own: Set<string>; liked?: string } | undefined;

export function rememberLibrary(owner: string, own: Set<string>, liked: string | undefined): void {
  library = { owner, own, liked };
}

export const ownPlaylistIDs = (user: string | undefined) => (user !== undefined && library?.owner === user ? library.own : new Set<string>());
export const likedPlaylistIDOf = (user: string | undefined) => (user !== undefined && library?.owner === user ? library.liked : undefined);

const algorithms = new Map<string, string>();

export function rememberAlgorithms(entries: [string, string][]): void {
  if (algorithms.size > 500) algorithms.clear();
  for (const [id, alg] of entries) algorithms.set(id, alg);
}

export const algorithm = (id: string) => algorithms.get(id);
