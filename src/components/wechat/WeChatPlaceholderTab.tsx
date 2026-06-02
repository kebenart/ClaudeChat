import type { LucideIcon } from 'lucide-react';

// MARK: - WeChatPlaceholderTab
//
// Used by the Contacts / Discover / Me tabs in the v1 WeChat layout — each
// will get a real implementation in a follow-up. For now they render an icon
// + title + body line so the user can see the 4-tab structure works.

interface Props {
  Icon: LucideIcon;
  title: string;
  body: string;
}

export default function WeChatPlaceholderTab({ Icon, title, body }: Props) {
  return (
    <div className="flex h-full flex-col items-center justify-center gap-3 text-center">
      <Icon className="h-12 w-12 text-muted-foreground" />
      <div className="text-base font-semibold">{title}</div>
      <div className="max-w-md px-4 text-xs text-muted-foreground">{body}</div>
    </div>
  );
}
