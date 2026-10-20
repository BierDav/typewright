// The Kotlin core (`sharedKotlin/`), shared with the Mac app: sync decisions, merges, invites, file kinds.
import { KtList } from "kotlin-stdlib";
import * as Core from "typewright-core";

export const {
  FileKind,
  IgnoreRules,
  LocalFile,
  RemoteEntry,
  SpaceInvite,
  SpaceSync,
  SyncAction,
} = Core;
export type FileKind = Core.FileKind;
export type IgnoreRules = Core.IgnoreRules;
export type SpaceSync = Core.SpaceSync;
export type SyncAction = Core.SyncAction;
export type SpaceInvite = Core.SpaceInvite;
export type LocalFile = Core.LocalFile;
export type RemoteEntry = Core.RemoteEntry;

export const SyncPolicy = Core.SyncPolicy.getInstance();
export const SpaceInvites = Core.SpaceInvites.getInstance();
export const TextMerge = Core.TextMerge.getInstance();
export const FileKinds = Core.FileKinds.getInstance();
export const Paths = Core.Paths.getInstance();
export const FuzzyMatch = Core.FuzzyMatch.getInstance();
export const SpaceOrder = Core.SpaceOrder.getInstance();
export const CodeHighlight = Core.CodeHighlight.getInstance();
export const PackageSpecs = Core.PackageSpecs.getInstance();

export function ktList<T>(items: readonly T[]): Core.KtList<T> {
  return KtList.fromJsArray(items);
}

export function jsList<T>(list: Core.KtList<T>): T[] {
  return [...list.asJsReadonlyArrayView()];
}
