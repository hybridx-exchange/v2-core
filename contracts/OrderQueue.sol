pragma solidity =0.5.16;

contract OrderQueue {
    //每一个价格对应一个订单队列(方向 -> 价格 -> 索引 -> data ================= 订单队列数据<先进先出>)
    mapping(uint => mapping(uint => mapping(uint => uint))) internal limitOrderQueueMap;
    //每一个价格对应一个订单队列(方向 -> 价格 -> 订单队列头索引)
    mapping(uint => mapping(uint => uint)) internal limitOrderQueueFront;
    //每一个价格对应一个订单队列(方向 -> 价格 -> 订单队列尾索引)
    mapping(uint => mapping(uint => uint)) internal limitOrderQueueRear;

    // Queue length，不考虑溢出的情况
    function length(
        uint direction,
        uint price)
    internal
    view
    returns (uint limitOrderQueueLength) {
        limitOrderQueueLength = limitOrderQueueRear[direction][price] - limitOrderQueueFront[direction][price];
    }

    // push
    function push(
        uint direction,
        uint price,
        uint data)
    internal {
        uint rear = limitOrderQueueRear[direction][price];
        limitOrderQueueMap[direction][price][rear] = data;
        limitOrderQueueRear[direction][price]++;
    }

    // pop
    function pop(
        uint direction,
        uint price)
    internal
    returns (uint data) {
        uint front = limitOrderQueueFront[direction][price];
        uint rear = limitOrderQueueRear[direction][price];
        if (front != rear){
            data = limitOrderQueueMap[direction][price][front];
            delete limitOrderQueueMap[direction][price][front];
            limitOrderQueueFront[direction][price]++;
        }
    }

    // del - 调用方保证元素一定存在
    function del(
        uint direction,
        uint price,
        uint data)
    internal {
        uint front = limitOrderQueueFront[direction][price];
        uint rear = limitOrderQueueRear[direction][price];
        require(front < rear, 'Invalid queue');

        //将元素从尾往前移，如果只有一个元素不需要进入循环
        uint pre = limitOrderQueueMap[direction][price][front];
        uint cur;
        for (uint i=front+1; i<rear; i++) {
            if (pre == data) {
                break;
            }

            cur = limitOrderQueueMap[direction][price][i];
            //将上一个位置的元素移到当前位置
            limitOrderQueueMap[direction][price][i] = pre;
            //为下一次做准备
            pre = cur;
        }

        //最后一定会找到与data相等的元素
        require(data == cur, 'Invalid data');

        delete limitOrderQueueMap[direction][price][front];
        limitOrderQueueFront[direction][price]++;
    }
}