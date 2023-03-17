// SPDX-License-Identifier: MIT

pragma solidity 0.8.9;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Address.sol";

interface IPancakeRouter {
    function getAmountsIn(uint amountOut, address[] calldata path) external view returns (uint[] memory amounts);
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
}

interface IRefferal {
    function userInfos(address _user) external view returns(address user,
        address refferBy,
        uint dateTime,
        uint totalRefer,
        uint totalRefer7,
        bool top10Refer);
}
contract Pools is Ownable, ReentrancyGuard {
    using Address for address payable;
    IPancakeRouter public pancakeRouter;
    IRefferal public refer;
    uint public taxPercent = 1250;
    uint public interestDecimal = 1000_000;
    uint public multiTimeInterest = 1095;
    address public immutable wBnb;
    address public immutable usd;
    struct Pool {
        //        uint timeLock;
        uint minLock;
        uint maxLock;
        uint currentInterest; // daily
        uint bonusInterest; // % base on user interest
        uint totalLock;
        bool enable;
        uint commPercent;
    }
    struct User {
        uint totalLock;
        uint startTime;
        uint totalReward;
        uint remainReward;
    }
    struct Claim {
        uint date;
        uint amount;
        uint totalLock;
        uint interrest;
    }
    struct Vote {
        address[] uservote;
        uint totalVote;
        bool status;
    }
    struct VoteConfig {
        address[] uservote;
        uint totalVote;
        uint pid;
        uint status; // 1 = request; 2 = success
        uint amount;
    }
    struct RankReward {
        uint minStart;
        uint stakingPercent;
        uint total;
        uint totalMember;
        uint rewardInMonth;
        uint remainInMonth;
    }
    struct Child {
        uint direct;
        uint downLine;
        mapping(address => bool) isChild;
    }
    Pool[] public pools;
    mapping(address => mapping(uint => User)) public users; // user => pId => detail
    mapping(address => uint) public userTotalLock; // user => totalLock
    mapping(address => uint) public userRank; // user => rank
    uint public usdTotalLock;
    uint public requestVoteConfigInterest;
    uint public requestVoteConfigComm;
    uint public giveRankRewardTime;
    mapping(uint => Vote) public votes;
    mapping(uint => mapping(uint => VoteConfig)) public voteConfigs; // vote type => requestVote => vote config detail, 1 = interest percent; 2 = comm percent
    mapping(address => mapping(uint => mapping(uint => bool))) public userVoteConfig; // user => vote type => requestVote => result
    mapping(address => mapping(uint => Claim[])) public userClaimed;
    mapping(address => mapping(uint => bool)) public userRankRewardClaimed; // user => month => is claimed
    mapping(address => Child) public childs;
    mapping(address => uint) public remainComm;
    mapping(address => uint) public volumeOntree;
    mapping(address => uint) public directStaked;
    mapping(address => uint) public lineStaked;
    mapping(address => uint) public totalComms;
    mapping(address => uint) public totalRewards;
    mapping(uint => RankReward) public rankRewards;

    uint[] public conditionMemOnTree = [0,2,10,30,50,100,200];
    uint[] public conditionVolumeOnTree = [100, 1000,5000,30000,100000,200000,300000];
    address public gnosisSafe;

    modifier onlyGnosisSafe() {
        require(gnosisSafe == _msgSender(), "Pools: caller is not the gnosisSafe");
        _;
    }

    event SetRoute(IPancakeRouter pancakeRouteAddress);
    event SetConditionMemOnTree(uint[] conditionMem);
    event SetConditionVolumeOnTree(uint[] conditionVolume);
    event SetRefer(IRefferal iRefer);
    event TogglePool(uint pid, bool enable);
    event AddPool(uint minLock, uint maxLock, uint currentInterest, uint bonusInterest, uint commPercent);
    event UpdateMinMaxPool(uint pid, uint minLock, uint maxLock);
    event UpdateInterestPool(uint pid, uint currentInterest);
    event UpdateCommPercent(uint pid, uint commPercent);
    event UpdatePool(uint pid, uint minLock, uint maxLock, uint bonusInterest, bool enable);
    event GetStuck(address payable user, uint amount);
    event VoteEvent(bool result);
    event VoteConfigEvent(bool result);
    event AdminRequestVoteConfig();

    constructor(IRefferal _refer, address gnosisSafeAddress, IPancakeRouter pancakeRouteAddress, address _wBnbAddress, address _usdAddress) {
        require(gnosisSafeAddress != address(0), "Pools::setGnosisSafe: invalid input");
        require(_wBnbAddress != address(0), "Pools::wBnbAddress: invalid input");
        require(_usdAddress != address(0), "Pools::usdAddress: invalid input");
        refer = _refer;
        gnosisSafe = gnosisSafeAddress;
        pancakeRouter = pancakeRouteAddress;
        wBnb = _wBnbAddress;
        usd = _usdAddress;
        // user default rank 0
        rankRewards[1] = RankReward(10000 ether, 20000, 0, 0, 0, 0);
        rankRewards[2] = RankReward(20000 ether, 5000, 0, 0, 0, 0);
        rankRewards[3] = RankReward(20000 ether, 5000, 0, 0, 0, 0);
        rankRewards[4] = RankReward(20000 ether, 5000, 0, 0, 0, 0);
        rankRewards[5] = RankReward(20000 ether, 5000, 0, 0, 0, 0);
    }
    function setRoute(IPancakeRouter pancakeRouteAddress) external onlyGnosisSafe {
        pancakeRouter = pancakeRouteAddress;
        emit SetRoute(pancakeRouteAddress);
    }
    function setConditionMemOnTree(uint[] memory conditionMem) external onlyGnosisSafe {
        conditionMemOnTree = conditionMem;
        emit SetConditionMemOnTree(conditionMem);
    }
    function setConditionVolumeOnTree(uint[] memory conditionVolume) external onlyGnosisSafe {
        conditionVolumeOnTree = conditionVolume;
        emit SetConditionVolumeOnTree(conditionVolume);
    }

    function bnbPrice() public view returns (uint[] memory amounts){
        address[] memory path = new address[](2);
        path[0] = usd;
        path[1] = wBnb;
        amounts = IPancakeRouter(pancakeRouter).getAmountsIn(1 ether, path);
    }

    function minMaxUSD2BNB(uint pid) public view returns (uint _min, uint _max) {
        Pool memory p = pools[pid];
        _min = p.minLock * 1 ether / bnbPrice()[0];
        _max = p.maxLock * 1 ether / bnbPrice()[0];
    }
    function bnb2USD(uint amount) public view returns (uint _usd) {
        _usd = bnbPrice()[0] * amount / 1 ether;
    }
    function setRefer(IRefferal iRefer) external onlyGnosisSafe {
        refer = iRefer;
        emit SetRefer(iRefer);
    }
    function setGnosisSafe(address gnosisSafeAddress) external onlyGnosisSafe {
        require(gnosisSafeAddress != address(0), "Pools::setGnosisSafe: invalid input");
        gnosisSafe = gnosisSafeAddress;
    }
    function getPools(uint[] memory pids) external pure returns(Pool[] memory poolsInfo) {
        poolsInfo = new Pool[](pids.length);
        for(uint i = 0; i < pids.length; i++) poolsInfo[i] = poolsInfo[pids[i]];
    }

    function getDays() public view returns(uint) {
        return block.timestamp / 1 days;
    }
    function getMonths() public view returns(uint) {
        return block.timestamp / 30 days;
    }
    function getUsersClaimedLength(uint pid, address user) external view returns(uint length) {
        return userClaimed[user][pid].length;
    }
    function getUsersClaimed(uint pid, address user, uint limit, uint skip) external view returns(Claim[] memory list, uint totalItem) {
        totalItem = userClaimed[user][pid].length;
        limit = limit <= totalItem - skip ? limit + skip : totalItem;
        uint lengthReturn = limit <= totalItem - skip ? limit : totalItem - skip;
        list = new Claim[](lengthReturn);
        for(uint i = skip; i < limit; i++) {
            list[i-skip] = userClaimed[user][pid][i];
        }
    }
    function currentReward(uint pid, address user) public view returns(uint) {
        User memory u = users[user][pid];
        if(u.totalLock == 0) return 0;
        Pool memory p = pools[pid];
        uint spendDays = getDays() - u.startTime / 1 days;
        if(userClaimed[user][pid].length > 0) {
            Claim memory claim = userClaimed[user][pid][userClaimed[user][pid].length-1];
            if(claim.date > u.startTime / 1 days) spendDays = getDays() - claim.date;
        }
        uint rw = p.currentInterest * u.totalLock * spendDays / interestDecimal;
        if(rw > u.remainReward) rw = u.remainReward;
        return rw;
    }

    function claimReward(uint pid) public nonReentrant {
        uint reward = currentReward(pid, _msgSender());
        uint tax = reward * taxPercent / interestDecimal;
        uint processAmount = reward - tax;
        if(reward > users[_msgSender()][pid].remainReward) reward = users[_msgSender()][pid].remainReward;
        if(reward > 0) {

            payable(_msgSender()).sendValue(processAmount);
            userClaimed[_msgSender()][pid].push(Claim(getDays(), reward, users[_msgSender()][pid].totalLock, pools[pid].currentInterest));
            users[_msgSender()][pid].totalReward += reward;
            users[_msgSender()][pid].remainReward -= reward;
            totalRewards[_msgSender()] += reward;
            remainComm[gnosisSafe] += tax;
            giveBonus(processAmount * pools[pid].bonusInterest / interestDecimal);
        }
    }
    function logVolume(uint amount) internal {
        uint _usd = bnb2USD(amount);
        address from = _msgSender();
        address _refferBy;
        for(uint i = 0; i < 7; i++) {
            (, _refferBy,,,,) = refer.userInfos(from);
            if(_refferBy == from) break;
            volumeOntree[_refferBy] += _usd;
            from = _refferBy;
            if(volumeOntree[_refferBy] >= 50_000 ether && volumeOntree[_refferBy] < 200_000 ether && userTotalLock[_refferBy] >= 500 ether && childs[_refferBy].direct >= 2 && childs[_refferBy].downLine >= 10) {
                userRank[_refferBy] = 1;
                rankRewards[1].totalMember += 1;
            }
            else if(volumeOntree[_refferBy] >= 200_000 ether && volumeOntree[_refferBy] < 500_000 ether && userTotalLock[_refferBy] >= 1000 ether && childs[_refferBy].direct >= 5 && childs[_refferBy].downLine >= 50) {
                userRank[_refferBy] = 2;
                rankRewards[1].totalMember -= 1;
                rankRewards[2].totalMember += 1;
            }
            else if(volumeOntree[_refferBy] >= 500_000 ether && volumeOntree[_refferBy] < 1000_000 ether && userTotalLock[_refferBy] >= 2000 ether && childs[_refferBy].direct >= 10 && childs[_refferBy].downLine >= 100) {
                userRank[_refferBy] = 3;
                rankRewards[2].totalMember -= 1;
                rankRewards[3].totalMember += 1;
            }
            else if(volumeOntree[_refferBy] >= 1000_000 ether && volumeOntree[_refferBy] < 3000_000 ether && userTotalLock[_refferBy] >= 4000 ether && childs[_refferBy].direct >= 10 && childs[_refferBy].downLine >= 200) {
                userRank[_refferBy] = 4;
                rankRewards[3].totalMember -= 1;
                rankRewards[4].totalMember += 1;
            }
            else if(volumeOntree[_refferBy] >= 3000_000 ether && userTotalLock[_refferBy] >= 50000 ether && childs[_refferBy].direct >= 10 && childs[_refferBy].downLine >= 500) {
                userRank[_refferBy] = 5;
                rankRewards[4].totalMember -= 1;
                rankRewards[5].totalMember += 1;
            }
        }

    }

    function giveRankRewardMonthly() external onlyGnosisSafe {
        require(block.timestamp - giveRankRewardTime > 30 days, "Pool::giveRankRewardMonthly: Not enough time");
        giveRankRewardTime = block.timestamp;
        for(uint i = 1; i < 6; i++) {
            rankRewards[i].total += rankRewards[i].remainInMonth;
            if(bnb2USD(rankRewards[i].total) >= rankRewards[i].minStart) {
                rankRewards[i].remainInMonth = rankRewards[i].total * 20 / 100;
                rankRewards[i].rewardInMonth = rankRewards[i].remainInMonth / rankRewards[i].totalMember;
                rankRewards[i].total -= rankRewards[i].remainInMonth;
            } else {
                rankRewards[i].remainInMonth = 0;
                rankRewards[i].rewardInMonth = 0;
            }
        }
    }
    function claimRankRewardMonthly(uint rid) external {
        require(rid > 0 && rid < 6, "Pool::claimRankRewardMonthly: Invalid rank id");
        require(!userRankRewardClaimed[_msgSender()][block.timestamp / getMonths()], "Pool::claimRankRewardMonthly: Claimed");
        userRankRewardClaimed[_msgSender()][block.timestamp / getMonths()] = true;
        payable(_msgSender()).sendValue(rankRewards[rid].rewardInMonth);
        rankRewards[rid].remainInMonth -= rankRewards[rid].rewardInMonth;
    }
    function giveRankReward(uint amount) internal {
        for(uint i = 1; i < 6; i++) {
            rankRewards[i].total += amount * rankRewards[i].stakingPercent / interestDecimal;
        }
    }
    function deposit(uint pid) external payable {

        Pool storage p = pools[pid];
        User storage u = users[_msgSender()][pid];
        uint _min;
        uint _max;
        (_min, _max) = minMaxUSD2BNB(pid);
        require(msg.value >= _min, 'Pools::deposit: Invalid amount');
        require(p.enable, 'Pools::deposit: pool disabled');
        if(u.totalLock > 0) require(block.timestamp - u.startTime < 60 minutes, 'Pools::deposit: Cant add more same pool after 7 days');
        //        if(u.totalLock > 0) require(block.timestamp - u.startTime < 7 days, 'Pools::deposit: Cant add more same pool after 7 days');
        uint tax = msg.value * taxPercent / interestDecimal;
        uint processAmount = msg.value - tax;

        claimReward(pid);
        u.totalLock += processAmount;
        u.startTime = block.timestamp;
        u.remainReward = p.currentInterest * processAmount * multiTimeInterest / interestDecimal + u.remainReward;
        p.totalLock += processAmount;
        giveComm(processAmount, pid);
        giveRankReward(processAmount);
        logVolume(processAmount);
        remainComm[owner()] += msg.value * 15 / 1000;
        remainComm[gnosisSafe] += tax;

        userTotalLock[_msgSender()] += msg.value;
        usdTotalLock += bnb2USD(msg.value);
    }
    function claimComm(address payable to) external nonReentrant {
        require(to != address(0), "Pools::claimComm: invalid input");
        require(remainComm[_msgSender()] > 0, 'Pools::claimComm: not comm');
        to.sendValue(remainComm[_msgSender()]);
        totalComms[_msgSender()] += remainComm[_msgSender()];
        remainComm[_msgSender()] = 0;
    }

    function giveBonus(uint totalComm) internal {
        uint currentComm = totalComm;
        address from = _msgSender();
        for(uint i = 0; i <= 7; i++) {
            address _refferBy;
            uint totalRefer;
            (, _refferBy,,totalRefer,,) = refer.userInfos(from);
            if((i == 7 || from == _refferBy)) {
                if(currentComm > 0) remainComm[gnosisSafe] += currentComm;
                break;
            } else {
                from = _refferBy;
                uint comm = totalComm / (2 ** (i+1));
                remainComm[_refferBy] += comm;
                currentComm -= comm;
            }

        }

    }
    function giveComm(uint amount, uint pid) internal {
        Pool memory p = pools[pid];
        uint totalComm = amount * p.commPercent / interestDecimal;
        uint currentComm = totalComm;
        address from = _msgSender();
        bool isContinue;
        for(uint i = 0; i <= 7; i++) {
            address _refferBy;
            (, _refferBy,,,,) = refer.userInfos(from);
            if((i == 7 || from == _refferBy)) {
                if(currentComm > 0) remainComm[gnosisSafe] += currentComm;
                break;
            } else {
                if(isContinue) continue;
                from = _refferBy;

                uint comm = totalComm / (2 ** (i+1));
                if(userTotalLock[_refferBy] > 0) {
                    remainComm[_refferBy] += comm;
                    currentComm -= comm;
                }
                else isContinue = true;
                if(i == 0) {
                    if(!childs[_refferBy].isChild[_msgSender()]) {
                        childs[_refferBy].direct += 1;
                    }
                } else {
                    if(!childs[_refferBy].isChild[_msgSender()]) {
                        childs[_refferBy].isChild[_msgSender()] = true;
                        childs[_refferBy].downLine += 1;
                    }
                }
            }

        }

    }
    function togglePool(uint pid, bool enable) external onlyGnosisSafe {
        pools[pid].enable = enable;
        emit TogglePool(pid, enable);
    }
    function updateMinMaxPool(uint pid, uint minLock, uint maxLock) external onlyGnosisSafe {
        pools[pid].minLock = minLock;
        pools[pid].maxLock = maxLock;
        emit UpdateMinMaxPool(pid, minLock, maxLock);
    }
    function updateInterestPool(uint pid, uint currentInterest) external onlyGnosisSafe {
        require(voteConfigs[1][requestVoteConfigInterest].status == 2, 'Pools::updateCommPercent: vote not success');
        pools[pid].currentInterest = currentInterest;
        emit UpdateInterestPool(pid, currentInterest);
    }
    function updateCommPercent(uint pid, uint commPercent) external onlyGnosisSafe {
        require(voteConfigs[2][requestVoteConfigComm].status == 2, 'Pools::updateCommPercent: vote not success');
        pools[pid].commPercent = commPercent;
        emit UpdateCommPercent(pid, commPercent);
    }
    function updatePool(uint pid, uint minLock, uint maxLock, uint bonusInterest, bool enable) external onlyGnosisSafe {
        pools[pid].minLock = minLock;
        pools[pid].maxLock = maxLock;
        pools[pid].bonusInterest = bonusInterest;
        pools[pid].enable = enable;
        emit UpdatePool(pid, minLock, maxLock, bonusInterest, enable);
    }
    function addPool(uint minLock, uint maxLock, uint currentInterest, uint bonusInterest, uint commPercent) external onlyGnosisSafe {
        pools.push(Pool(minLock * 1 ether, maxLock * 1 ether, currentInterest, bonusInterest, 0, true, commPercent));
        emit AddPool(minLock, maxLock, currentInterest, bonusInterest, commPercent);
    }
    function inCaseTokensGetStuck(IERC20 token) external onlyGnosisSafe {
        uint _amount = token.balanceOf(address(this));
        require(token.transfer(msg.sender, _amount));
    }

    function adminRequestVoteConfig(uint pid, uint voteType, uint amount) external onlyGnosisSafe {
        require(pools[pid].enable, 'Pools::adminRequestVoteConfig: pool not active');

        uint reqVote;
        if(voteType == 1) {
            requestVoteConfigInterest += 1;
            reqVote = requestVoteConfigInterest;
        }
        else {
            requestVoteConfigComm += 1;
            reqVote = requestVoteConfigComm;
        }
        voteConfigs[voteType][reqVote].pid = pid;
        voteConfigs[voteType][reqVote].status = 1;
        voteConfigs[voteType][reqVote].amount = amount;

        emit AdminRequestVoteConfig();
    }
    function voteConfig(uint voteType, bool result) external {

        uint reqVote;
        if(voteType == 1) {
            reqVote = requestVoteConfigInterest;
        }
        else {
            reqVote = requestVoteConfigComm;
        }
        VoteConfig storage v = voteConfigs[voteType][reqVote];
        require(v.status == 1, 'Pools::voteConfig: Vote is not requested');
        require(result != userVoteConfig[_msgSender()][voteType][reqVote], 'Pools::vote: Same result');
        if(userVoteConfig[_msgSender()][voteType][reqVote]) v.totalVote -= userTotalLock[_msgSender()];
        else v.totalVote += userTotalLock[_msgSender()];
        userVoteConfig[_msgSender()][voteType][reqVote] = result;

        if(v.totalVote >= address(this).balance * 50 / 100) {
            v.status = 2;
        }
        emit VoteConfigEvent(result);
    }
}
