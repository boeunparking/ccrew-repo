import { SESv2Client, SendEmailCommand } from '@aws-sdk/client-sesv2';

const REGION = process.env.AWS_REGION || 'ap-northeast-2';
const FROM_ADDRESS = process.env.SES_FROM_ADDRESS || 'noreply@cloudduck.cloud';

const ses = new SESv2Client({ region: REGION });

export async function sendWinnerEmail({ to, auctionName, price }) {
  await ses.send(
    new SendEmailCommand({
      FromEmailAddress: FROM_ADDRESS,
      Destination: { ToAddresses: [to] },
      Content: {
        Simple: {
          Subject: { Data: `[CloudDuck] "${auctionName}" 낙찰되었습니다` },
          Body: {
            Text: {
              Data: `축하합니다! "${auctionName}" 경매에서 ${price.toLocaleString()}원으로 낙찰되었습니다.\n마이페이지에서 결제를 진행해 주세요.`,
            },
          },
        },
      },
    })
  );
}
